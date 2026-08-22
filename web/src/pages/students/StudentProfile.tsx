import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStudent, getStudentEnrollments, getGuardians, updateStudent, setStudentStatus,
  getStudentBalance, getStudentInvoices, getStudentPayments, attendanceSummary,
  getSiblings, getStudentLinks, removeStudentLink, studentJoinFamily, getStudentFamilyId,
  listFamilyParents, createParentLogin, unlinkParent, getChallan, type Challan,
  getStudentMonthlyFee, getEnrollmentDiscounts, addDiscount, setDiscountStatus,
  recordPayment, billStudentMonth, deferInvoice, undoDefer, addAdjustment,
  getStudentMonthTests, getStudentMonthAttendance,
  type StudentProfile as Student, type EnrollmentInfo, type InvoiceBalance, type MonthTestRow,
} from '@/lib/db'
import {
  GENDERS, STUDENT_STATUS_LABELS, PAYMENT_METHODS, PAYMENT_STATUS_LABELS,
  ATTENDANCE_STATUSES, ATTENDANCE_SHORT, DISCOUNT_TYPES,
} from '@/lib/constants'
import { fmtPKR, fmtDate, waLink, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, ADMIN_ROLES, type Role } from '@/auth/roles'
import { Receipt, type ReceiptData } from '@/components/Receipt'
import { useSchoolName } from '@/hooks/useSchoolName'
import { ChallanPrint } from '@/pages/fees/ChallanPrint'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const FINANCE_ROLES: Role[] = ['owner', 'principal', 'admin_clerk', 'accountant']
const TABS = ['Overview', 'Fees', 'Attendance & Tests'] as const
type Tab = (typeof TABS)[number]

// ---- month helpers ----
function ym(dateISO: string): string { return dateISO.slice(0, 7) }
function monthFirst(y: string): string { return `${y}-01` }
function monthLast(y: string): string {
  const [yy, mm] = y.split('-').map(Number)
  return `${y}-${String(new Date(yy, mm, 0).getDate()).padStart(2, '0')}`
}
function monthLabel(y: string): string {
  const [yy, mm] = y.split('-').map(Number)
  return new Date(yy, mm - 1, 1).toLocaleDateString('en-PK', { month: 'long', year: 'numeric' })
}
/** Inclusive list of 'YYYY-MM' from start→end (newest first), capped for safety. */
function monthsRange(startYM: string, endYM: string): string[] {
  const out: string[] = []
  let [y, m] = startYM.split('-').map(Number)
  const [ey, em] = endYM.split('-').map(Number)
  for (let i = 0; i < 36; i++) {
    if (y > ey || (y === ey && m > em)) break
    out.push(`${y}-${String(m).padStart(2, '0')}`)
    m++; if (m > 12) { m = 1; y++ }
  }
  return out.reverse()
}

export function StudentProfile({ studentId, onBack, onOpen }: { studentId: string; onBack: () => void; onOpen?: (id: string) => void }) {
  const { profile } = useAuth()
  const role = profile?.role
  const canEdit = !!role && ADMIN_ROLES.includes(role) && role !== 'readonly' && role !== 'accountant'
  const canStatus = !!role && APPROVER_ROLES.includes(role)
  const canFinance = !!role && FINANCE_ROLES.includes(role)

  const student = useQuery({ queryKey: ['student', studentId], queryFn: () => getStudent(studentId) })
  const enroll = useQuery({ queryKey: ['enrollments', studentId], queryFn: () => getStudentEnrollments(studentId) })
  const guardians = useQuery({ queryKey: ['guardians', studentId], queryFn: () => getGuardians(studentId) })

  const [tab, setTab] = useState<Tab>('Overview')

  if (student.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (student.isError) return <p className="text-sm text-red-600">{(student.error as Error).message}</p>
  const s = student.data!
  const cur = enroll.data?.[0]
  const wa = waLink(s.whatsapp || s.phone)

  return (
    <div>
      <button onClick={onBack} className="text-sm text-brand-700 hover:underline">← Back to students</button>

      <div className="mt-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="text-xl font-semibold text-slate-800">{s.full_name}</h1>
            <StatusBadge status={s.status} />
          </div>
          <div className="mt-0.5 text-sm text-slate-500">
            GR {s.gr_no ?? '—'}{s.father_name ? ` · ${s.father_name}` : ''}
            {cur ? ` · ${cur.class_name}${cur.section_name ? ` (${cur.section_name})` : ''}${cur.roll_no ? ` · Roll ${cur.roll_no}` : ''}` : ''}
          </div>
        </div>
        <div className="flex flex-wrap gap-2">
          {wa && (
            <a href={wa} target="_blank" rel="noopener noreferrer"
              className="rounded bg-emerald-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-emerald-700">
              WhatsApp
            </a>
          )}
          {canStatus && <StatusAction student={s} />}
        </div>
      </div>

      <div className="mt-4 flex gap-1 border-b border-slate-200">
        {TABS.map((t) => (
          <button key={t} onClick={() => setTab(t)}
            className={`-mb-px border-b-2 px-4 py-2 text-sm ${tab === t ? 'border-brand-600 font-medium text-brand-700' : 'border-transparent text-slate-500 hover:text-slate-700'}`}>
            {t}
          </button>
        ))}
      </div>

      <div className="mt-5">
        {tab === 'Overview' && (
          <Overview student={s} guardians={guardians.data ?? []} enrollments={enroll.data ?? []} canEdit={canEdit} onOpen={onOpen} />
        )}
        {tab === 'Fees' && (
          !canFinance
            ? <p className="text-sm text-slate-500">You don’t have access to fees.</p>
            : cur
              ? <FeesTab studentId={studentId} student={s} enrollment={cur} canApprove={canStatus} />
              : <p className="text-sm text-slate-500">No current enrolment — nothing to bill yet.</p>
        )}
        {tab === 'Attendance & Tests' && (
          cur
            ? <AttendanceTestsTab student={s} enrollment={cur} />
            : <p className="text-sm text-slate-500">No enrolment yet.</p>
        )}
      </div>
    </div>
  )
}

function StatusBadge({ status }: { status: string }) {
  const map: Record<string, string> = {
    active: 'bg-emerald-100 text-emerald-700',
    struck_off: 'bg-red-100 text-red-700',
    withdrawn: 'bg-amber-100 text-amber-700',
    graduated: 'bg-sky-100 text-sky-700',
  }
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${map[status] ?? 'bg-slate-100 text-slate-600'}`}>
      {STUDENT_STATUS_LABELS[status] ?? status}
    </span>
  )
}

function StatusAction({ student }: { student: Student }) {
  const qc = useQueryClient()
  const active = student.status === 'active'
  const m = useMutation({
    mutationFn: (payload: { status: string; reason?: string }) => setStudentStatus(student.id, payload.status, payload.reason),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['student', student.id] })
      qc.invalidateQueries({ queryKey: ['enrollments', student.id] })
      qc.invalidateQueries({ queryKey: ['students'] })
    },
  })
  function strikeOff() {
    const reason = window.prompt('Reason for striking off this student?')
    if (reason === null) return
    m.mutate({ status: 'struck_off', reason: reason || undefined })
  }
  return active ? (
    <button onClick={strikeOff} disabled={m.isPending}
      className="rounded border border-red-300 px-3 py-1.5 text-sm font-medium text-red-700 hover:bg-red-50 disabled:opacity-60">
      {m.isPending ? '…' : 'Strike off'}
    </button>
  ) : (
    <button onClick={() => m.mutate({ status: 'active' })} disabled={m.isPending}
      className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
      {m.isPending ? '…' : 'Reinstate'}
    </button>
  )
}

function Overview({
  student, guardians, enrollments, canEdit, onOpen,
}: {
  student: Student
  guardians: { id: string; name: string; relation: string | null; phone: string | null; whatsapp: string | null; is_primary: boolean }[]
  enrollments: EnrollmentInfo[]
  canEdit: boolean
  onOpen?: (id: string) => void
}) {
  const links = useQuery({ queryKey: ['studentLinks', student.id], queryFn: () => getStudentLinks(student.id) })
  const siblings = useQuery({ queryKey: ['siblings', student.id], queryFn: () => getSiblings(student.id) })
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [f, setF] = useState(student)
  const orNull = (v: string | null) => (v && v.trim() !== '' ? v.trim() : null)
  const save = useMutation({
    mutationFn: () => updateStudent(student.id, {
      full_name: f.full_name.trim(),
      father_name: orNull(f.father_name), mother_name: orNull(f.mother_name),
      gender: orNull(f.gender), dob: orNull(f.dob), b_form: orNull(f.b_form),
      phone: orNull(f.phone), whatsapp: orNull(f.whatsapp), address: orNull(f.address),
    }),
    onSuccess: () => { qc.invalidateQueries({ queryKey: ['student', student.id] }); setEditing(false) },
  })
  const unlink = useMutation({
    mutationFn: (linkId: string) => removeStudentLink(linkId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['studentLinks', student.id] }),
  })

  // Which family this student bills under. Needed to tell a sibling who shares
  // the family from one who only shares a father's name — before migration 0036
  // every child had a family to themselves, so "linked" meant nothing to the
  // money, and any student admitted before then is still in that state.
  const myFamily = useQuery({
    queryKey: ['studentFamily', student.id],
    queryFn: () => getStudentFamilyId(student.id),
  })

  const join = useMutation({
    mutationFn: (siblingId: string) => studentJoinFamily(student.id, siblingId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['studentFamily', student.id] })
      qc.invalidateQueries({ queryKey: ['studentLinks', student.id] })
      qc.invalidateQueries({ queryKey: ['siblings', student.id] })
      qc.invalidateQueries({ queryKey: ['studentFees', student.id] })
    },
  })

  const linkedIds = new Set((links.data ?? []).map((l) => l.student_id))
  const inferred = (siblings.data ?? []).filter((s) => !linkedIds.has(s.id))

  if (editing) {
    const upd = (k: keyof Student, v: string) => setF((p) => ({ ...p, [k]: v }))
    return (
      <form className="max-w-2xl space-y-3" onSubmit={(e) => { e.preventDefault(); save.mutate() }}>
        <div className="grid gap-3 sm:grid-cols-2">
          <L label="Full name"><input required value={f.full_name} onChange={(e) => upd('full_name', e.target.value)} className={FIELD} /></L>
          <L label="Father's name"><input value={f.father_name ?? ''} onChange={(e) => upd('father_name', e.target.value)} className={FIELD} /></L>
          <L label="Mother's name"><input value={f.mother_name ?? ''} onChange={(e) => upd('mother_name', e.target.value)} className={FIELD} /></L>
          <L label="Gender">
            <select value={f.gender ?? ''} onChange={(e) => upd('gender', e.target.value)} className={FIELD}>
              <option value="">—</option>{GENDERS.map((g) => <option key={g.value} value={g.value}>{g.label}</option>)}
            </select>
          </L>
          <L label="Date of birth"><input type="date" max={todayISO()} value={f.dob ?? ''} onChange={(e) => upd('dob', e.target.value)} className={FIELD} /></L>
          <L label="B-Form No"><input value={f.b_form ?? ''} onChange={(e) => upd('b_form', e.target.value)} className={FIELD} /></L>
          <L label="Phone"><input value={f.phone ?? ''} onChange={(e) => upd('phone', e.target.value)} className={FIELD} /></L>
          <L label="WhatsApp"><input value={f.whatsapp ?? ''} onChange={(e) => upd('whatsapp', e.target.value)} className={FIELD} /></L>
          <L label="Address" wide><input value={f.address ?? ''} onChange={(e) => upd('address', e.target.value)} className={FIELD} /></L>
        </div>
        {save.isError && <p className="text-sm text-red-600">{(save.error as Error).message}</p>}
        <div className="flex gap-2">
          <button type="submit" disabled={save.isPending} className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {save.isPending ? 'Saving…' : 'Save'}
          </button>
          <button type="button" onClick={() => { setF(student); setEditing(false) }} className="rounded border border-slate-300 px-4 py-2 text-sm hover:bg-slate-50">Cancel</button>
        </div>
      </form>
    )
  }

  return (
    <div className="grid gap-4 md:grid-cols-2">
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="flex items-center justify-between">
          <div className="text-xs uppercase tracking-wide text-slate-500">Bio-data</div>
          {canEdit && <button onClick={() => { setF(student); setEditing(true) }} className="text-sm text-brand-700 hover:underline">Edit</button>}
        </div>
        <dl className="mt-2 space-y-1.5 text-sm">
          <Info label="GR No" value={student.gr_no} />
          <Info label="Admission No" value={student.admission_no} />
          <Info label="Father" value={student.father_name} />
          <Info label="Mother" value={student.mother_name} />
          <Info label="Gender" value={student.gender ? (GENDERS.find((g) => g.value === student.gender)?.label ?? student.gender) : null} />
          <Info label="Date of birth" value={student.dob ? fmtDate(student.dob) : null} />
          <Info label="B-Form" value={student.b_form} />
          <Info label="Phone" value={student.phone} />
          <Info label="WhatsApp" value={student.whatsapp} />
          <Info label="Address" value={student.address} />
          <Info label="Admitted" value={student.admission_date ? fmtDate(student.admission_date) : null} />
        </dl>
      </div>

      <div className="space-y-4">
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Guardian / contact</div>
          <dl className="mt-2 space-y-1.5 text-sm">
            <Info label="Father" value={student.father_name} />
            <Info label="Mother" value={student.mother_name} />
            <Info label="Phone" value={student.phone} />
            <Info label="WhatsApp" value={student.whatsapp} />
          </dl>
          {guardians.length > 0 && (
            <ul className="mt-2 space-y-1 border-t border-slate-100 pt-2 text-sm">
              {guardians.map((g) => (
                <li key={g.id} className="flex justify-between">
                  <span className="text-slate-700">{g.name}{g.relation ? ` · ${g.relation}` : ''}{g.is_primary ? ' · primary' : ''}</span>
                  <span className="text-slate-500">{g.phone ?? g.whatsapp ?? ''}</span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Enrolment history</div>
          {enrollments.length === 0 ? (
            <p className="mt-2 text-sm text-slate-400">No enrolments.</p>
          ) : (
            <ul className="mt-2 space-y-1.5 text-sm">
              {enrollments.map((e, i) => (
                <li key={i} className="flex justify-between">
                  <span className="text-slate-700">{e.session_name} · {e.class_name}{e.section_name ? ` (${e.section_name})` : ''}</span>
                  <span className="text-slate-500">{e.roll_no ? `Roll ${e.roll_no}` : ''}</span>
                </li>
              ))}
            </ul>
          )}
        </div>

        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Siblings / family</div>
          {(links.data?.length ?? 0) === 0 && inferred.length === 0 ? (
            <p className="mt-2 text-sm text-slate-400">No linked family. Add siblings/relatives during admission.</p>
          ) : (
            <ul className="mt-2 space-y-1.5 text-sm">
              {links.data?.map((l) => (
                <li key={l.link_id} className="flex items-start justify-between gap-2">
                  <div className="min-w-0">
                    <button onClick={() => onOpen?.(l.student_id)} disabled={!onOpen}
                      className="text-left text-slate-700 hover:text-brand-700 hover:underline disabled:cursor-default disabled:no-underline">
                      {l.full_name}{l.gr_no ? ` · ${l.gr_no}` : ''}{l.class_name ? ` · ${l.class_name}` : ''}
                      {l.relation ? <span className="text-slate-400"> · {l.relation}</span> : ''}
                    </button>
                    <FamilyState mine={myFamily.data} theirs={l.family_id} canEdit={canEdit}
                      pending={join.isPending}
                      onJoin={() => join.mutate(l.student_id)} />
                  </div>
                  {canEdit && (
                    <button onClick={() => unlink.mutate(l.link_id)} className="text-xs text-slate-400 hover:text-red-600">✕</button>
                  )}
                </li>
              ))}
              {inferred.length > 0 && (
                <li className="pt-1 text-xs text-slate-400">Possible (same father’s name):</li>
              )}
              {inferred.map((sib) => (
                <li key={sib.id}>
                  <button onClick={() => onOpen?.(sib.id)} disabled={!onOpen}
                    className="text-left text-slate-500 hover:text-brand-700 hover:underline disabled:cursor-default disabled:no-underline">
                    {sib.full_name}{sib.gr_no ? ` · ${sib.gr_no}` : ''}
                  </button>
                  <FamilyState mine={myFamily.data} theirs={sib.family_id} canEdit={canEdit}
                    pending={join.isPending}
                    onJoin={() => join.mutate(sib.id)} />
                </li>
              ))}
            </ul>
          )}
          {join.isError && (
            <p className="mt-2 text-xs text-red-600">{(join.error as Error).message}</p>
          )}
        </div>

        <ParentAccess familyId={myFamily.data ?? null} canEdit={canEdit} />
      </div>
    </div>
  )
}

/**
 * Give this child's family a login for the parent portal.
 *
 * The portal (migration 0033) was complete and completely unreachable: nothing
 * in the product wrote profiles.family_id, so my_family_id() was always null
 * and every portal read refused. This panel is the missing link.
 *
 * It lives on the student profile rather than in Settings because that is where
 * the school is already standing when a father asks for access — looking at his
 * child. Access is granted to the FAMILY, so it covers every sibling at once.
 */
function ParentAccess({ familyId, canEdit }: { familyId: string | null; canEdit: boolean }) {
  const qc = useQueryClient()
  const [open, setOpen] = useState(false)
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [done, setDone] = useState<string | null>(null)

  const parents = useQuery({
    queryKey: ['familyParents', familyId],
    queryFn: () => listFamilyParents(familyId!),
    enabled: !!familyId,
  })

  const create = useMutation({
    mutationFn: () => createParentLogin({
      email: email.trim(), password, full_name: fullName.trim(), family_id: familyId!,
    }),
    onSuccess: (r) => {
      // Shown once, deliberately: the password is not stored anywhere we can
      // read back, so if the clerk does not write it down now it has to be
      // reset. Saying so is better than a silent success.
      setDone(`${r.email} — password: ${password}`)
      setFullName(''); setEmail(''); setPassword(''); setOpen(false)
      qc.invalidateQueries({ queryKey: ['familyParents', familyId] })
    },
  })

  const revoke = useMutation({
    mutationFn: (profileId: string) => unlinkParent(profileId),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['familyParents', familyId] }),
  })

  const valid = /^\S+@\S+\.\S+$/.test(email.trim()) && password.length >= 6

  if (!familyId) return null

  return (
    <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
      <div className="text-xs uppercase tracking-wide text-slate-500">Parent portal</div>

      {parents.isLoading && <p className="mt-2 text-sm text-slate-400">Checking…</p>}

      {parents.data?.length === 0 && (
        <p className="mt-2 text-sm text-slate-400">
          No login yet. A parent login shows fees, attendance and released results for every child
          in this family.
        </p>
      )}

      {(parents.data?.length ?? 0) > 0 && (
        <ul className="mt-2 space-y-1.5 text-sm">
          {parents.data?.map((p) => (
            <li key={p.profile_id} className="flex items-start justify-between gap-2">
              <div className="min-w-0">
                <div className="truncate text-slate-700">{p.full_name || p.email}</div>
                <div className="truncate text-xs text-slate-400">{p.email}</div>
                {!p.active && <div className="text-xs text-amber-700">Access removed</div>}
              </div>
              {canEdit && p.active && (
                <button onClick={() => revoke.mutate(p.profile_id)} disabled={revoke.isPending}
                  className="shrink-0 text-xs text-slate-400 hover:text-red-600 disabled:opacity-50">
                  Remove
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {done && (
        <div className="mt-3 rounded border border-money-200 bg-money-50 p-2 text-xs text-money-800">
          <div className="font-medium">Login created — write this down now</div>
          <div className="mt-0.5 break-all font-mono">{done}</div>
          <div className="mt-1 text-money-700">
            The password is not saved anywhere you can read it back. If it is lost the parent has to
            use “Forgot password”.
          </div>
        </div>
      )}

      {canEdit && !open && (
        <button onClick={() => { setOpen(true); setDone(null) }}
          className="mt-3 rounded border border-slate-300 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50">
          + Give this family a login
        </button>
      )}

      {canEdit && open && (
        <form className="mt-3 space-y-2" onSubmit={(e) => { e.preventDefault(); if (valid) create.mutate() }}>
          <input value={fullName} onChange={(e) => setFullName(e.target.value)} placeholder="Parent's name"
            className="w-full rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none" />
          <input type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="father@example.com"
            className="w-full rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none" />
          <input type="text" value={password} onChange={(e) => setPassword(e.target.value)} placeholder="temporary password (min 6)"
            className="w-full rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none" />
          {create.isError && <p className="text-xs text-red-600">{(create.error as Error).message}</p>}
          <div className="flex gap-2">
            <button type="submit" disabled={!valid || create.isPending}
              className="rounded bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {create.isPending ? 'Creating…' : 'Create login'}
            </button>
            <button type="button" onClick={() => setOpen(false)}
              className="rounded border border-slate-300 px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-50">
              Cancel
            </button>
          </div>
        </form>
      )}

      {revoke.isError && <p className="mt-2 text-xs text-red-600">{(revoke.error as Error).message}</p>}
    </div>
  )
}

// =============================================================================
// Fees tab — monthly-fee header, month-by-month list, settle/waive, discounts
// =============================================================================
type MonthState = 'paid' | 'partial' | 'unpaid' | 'unbilled' | 'deferred' | 'free'
interface MonthRow {
  key: string; label: string; state: MonthState
  charge: number; due: number; invoice: InvoiceBalance | null
}

function FeesTab({
  studentId, student, enrollment, canApprove,
}: { studentId: string; student: Student; enrollment: EnrollmentInfo; canApprove: boolean }) {
  const qc = useQueryClient()
  const balance = useQuery({ queryKey: ['balance', studentId], queryFn: () => getStudentBalance(studentId) })
  const invoices = useQuery({ queryKey: ['invoices', studentId], queryFn: () => getStudentInvoices(studentId) })
  const payments = useQuery({ queryKey: ['payments', studentId], queryFn: () => getStudentPayments(studentId) })
  const monthlyFee = useQuery({ queryKey: ['monthlyFee', enrollment.enrollment_id], queryFn: () => getStudentMonthlyFee(enrollment.enrollment_id) })
  const discounts = useQuery({ queryKey: ['enrollmentDiscounts', enrollment.enrollment_id], queryFn: () => getEnrollmentDiscounts(enrollment.enrollment_id) })

  const [receipt, setReceipt] = useState<ReceiptData | null>(null)
  const feeSchoolName = useSchoolName()
  // Single-challan reprint. Fetched on demand rather than with the month rows:
  // a clerk prints one slip out of twelve, and pre-loading twelve challans to
  // support that would make the tab slower for everyone.
  const [challan, setChallan] = useState<Challan | null>(null)
  const [challanErr, setChallanErr] = useState<string | null>(null)
  async function printOne(invoiceId: string) {
    setChallanErr(null)
    try { setChallan(await getChallan(invoiceId)) }
    catch (e) { setChallanErr((e as Error).message) }
  }
  const [pay, setPay] = useState<null | { month?: string; billMonthISO?: string; defaultAmount: number; note: string }>(null)
  const [settle, setSettle] = useState(false)
  const [showDiscount, setShowDiscount] = useState(false)
  const [showActivity, setShowActivity] = useState(false)
  const [defer, setDefer] = useState<null | { invoiceId?: string; billMonthISO?: string; label: string }>(null)

  function refresh() {
    qc.invalidateQueries({ queryKey: ['balance', studentId] })
    qc.invalidateQueries({ queryKey: ['invoices', studentId] })
    qc.invalidateQueries({ queryKey: ['payments', studentId] })
    qc.invalidateQueries({ queryKey: ['monthlyFee', enrollment.enrollment_id] })
    qc.invalidateQueries({ queryKey: ['enrollmentDiscounts', enrollment.enrollment_id] })
  }

  const net = monthlyFee.data?.net ?? 0
  const grossFee = monthlyFee.data?.gross ?? 0
  const approvedDiscounts = (discounts.data ?? []).filter((d) => d.status === 'approved')
  const isFree = net === 0 && grossFee > 0 && approvedDiscounts.length > 0

  // Build the month rows from session start → current month.
  const rows: MonthRow[] = useMemo(() => {
    const startISO = enrollment.session_starts ?? student.admission_date ?? todayISO()
    const todayYM = ym(todayISO())
    const endYM = enrollment.session_ends ? (ym(enrollment.session_ends) < todayYM ? ym(enrollment.session_ends) : todayYM) : todayYM
    let startYM = ym(startISO)
    if (student.admission_date && ym(student.admission_date) > startYM) startYM = ym(student.admission_date)
    if (startYM > endYM) startYM = endYM
    const months = monthsRange(startYM, endYM)
    const byMonth = new Map<string, InvoiceBalance>()
    for (const inv of invoices.data ?? []) {
      if (inv.period_month) byMonth.set(ym(inv.period_month), inv)
    }
    return months.map((mkey) => {
      const inv = byMonth.get(mkey) ?? null
      if (inv) {
        const due = inv.charge - inv.allocated
        let state: MonthState
        if (inv.charge === 0) state = 'free'
        else if (due <= 0) state = 'paid'
        else if (inv.deferred_until || inv.defer_reason) state = 'deferred'
        else if (inv.allocated > 0) state = 'partial'
        else state = 'unpaid'
        return { key: mkey, label: monthLabel(mkey), state, charge: inv.charge, due, invoice: inv }
      }
      // not billed yet
      const state: MonthState = net === 0 && grossFee > 0 ? 'free' : 'unbilled'
      return { key: mkey, label: monthLabel(mkey), state, charge: net, due: net, invoice: null }
    })
  }, [invoices.data, enrollment, student.admission_date, net, grossFee])

  const bal = balance.data ?? 0
  const hasOlderUnpaid = (fromKey: string) =>
    rows.some((r) => r.key < fromKey && (r.state === 'unpaid' || r.state === 'partial' || r.state === 'unbilled' || r.state === 'deferred'))

  return (
    <div className="space-y-4">
      {/* Header: monthly fee + balance + actions */}
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Monthly fee ({enrollment.class_name})</div>
          {monthlyFee.isLoading ? <div className="mt-1 text-slate-400">…</div> : (
            <div className="mt-1 flex items-baseline gap-2">
              <span className="text-2xl font-semibold text-slate-800">{fmtPKR(net)}</span>
              {grossFee > net && <span className="text-sm text-slate-400 line-through">{fmtPKR(grossFee)}</span>}
              {isFree && <span className="rounded bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700">Free student</span>}
            </div>
          )}
          {grossFee === 0 && !monthlyFee.isLoading && (
            <p className="mt-1 text-xs text-amber-600">No monthly fee set for this class — set it in Settings → Fee structure.</p>
          )}
        </div>
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Current balance</div>
          <div className={`mt-1 text-2xl font-semibold ${bal > 0 ? 'text-red-600' : bal < 0 ? 'text-sky-600' : 'text-emerald-600'}`}>
            {balance.isLoading ? '…' : fmtPKR(bal)}
          </div>
          <div className="mt-2 flex flex-wrap gap-2">
            <button onClick={() => setPay({ defaultAmount: bal > 0 ? bal : 0, note: '' })}
              className="rounded bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700">Record payment</button>
            {bal > 0 && (
              <button onClick={() => setSettle(true)}
                className="rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-50">Settle balance</button>
            )}
          </div>
        </div>
      </div>

      {/* Discount strip */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="flex items-center justify-between">
          <div className="text-xs uppercase tracking-wide text-slate-500">Discount on fee</div>
          <div className="flex gap-3">
            <button onClick={() => setShowDiscount(true)} className="text-sm text-brand-700 hover:underline">Propose discount</button>
          </div>
        </div>
        {discounts.isLoading ? <p className="mt-2 text-sm text-slate-400">…</p> : (discounts.data?.length ?? 0) === 0 ? (
          <p className="mt-2 text-sm text-slate-400">No discount. The full monthly fee applies.</p>
        ) : (
          <ul className="mt-2 space-y-1 text-sm">
            {discounts.data?.map((d) => (
              <li key={d.id} className="flex items-center justify-between gap-2">
                <span className="text-slate-700">
                  {DISCOUNT_TYPES.find((t) => t.value === d.type)?.label ?? d.type} · {d.is_percent ? `${d.amount}%` : fmtPKR(d.amount)}
                  {d.reason ? <span className="text-slate-400"> · {d.reason}</span> : ''}
                </span>
                <DiscountStatusPill status={d.status} />
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Month-by-month list */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="text-xs uppercase tracking-wide text-slate-500">Fee by month</div>
        <div className="mt-2 divide-y divide-slate-100">
          {rows.length === 0 && <p className="py-3 text-sm text-slate-400">No months to show yet.</p>}
          {rows.map((r) => (
            <MonthLine key={r.key} row={r} enrollment={enrollment}
              onPay={() => setPay({ month: r.key, billMonthISO: r.invoice ? undefined : monthFirst(r.key), defaultAmount: r.due, note: `Fee · ${r.label}` })}
              onDelay={() => setDefer({ invoiceId: r.invoice?.invoice_id, billMonthISO: r.invoice ? undefined : monthFirst(r.key), label: r.label })}
              onUndoDefer={r.invoice ? () => { undoDefer(r.invoice!.invoice_id).then(refresh) } : undefined}
              onPrint={r.invoice ? () => { void printOne(r.invoice!.invoice_id) } : undefined}
            />
          ))}
        </div>
        {rows.some((r) => r.state === 'unbilled') && (
          <p className="mt-3 text-xs text-slate-400">Un-billed months are shown from the class fee. Marking one paid bills it for this student automatically.</p>
        )}
      </div>

      {/* Activity / ledger (collapsible) */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <button onClick={() => setShowActivity((v) => !v)} className="flex w-full items-center justify-between text-xs uppercase tracking-wide text-slate-500">
          <span>Activity &amp; receipts</span>
          <span className="text-slate-400">{showActivity ? 'Hide' : 'Show'}</span>
        </button>
        {showActivity && (
          <table className="mt-3 w-full text-sm">
            <thead className="text-left text-xs text-slate-400"><tr><th className="py-1">Receipt</th><th>Date</th><th>Amount</th><th>Method</th><th>Status</th><th>Note</th></tr></thead>
            <tbody>
              {payments.data?.map((p) => (
                <tr key={p.id} className="border-t border-slate-100">
                  <td className="py-1.5">{p.receipt_no != null ? `#${p.receipt_no}` : '—'}</td>
                  <td>{fmtDate(p.created_at)}</td>
                  <td className={p.amount < 0 ? 'text-red-600' : ''}>{fmtPKR(p.amount)}</td>
                  <td>{PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method}</td>
                  <td><PaymentStatusPill status={p.status} /></td>
                  <td className="text-slate-500">{p.reversal_of ? 'Reversal' : p.note}</td>
                </tr>
              ))}
              {payments.data?.length === 0 && <tr><td colSpan={6} className="py-3 text-slate-400">No payments yet.</td></tr>}
            </tbody>
          </table>
        )}
      </div>

      {challanErr && <p className="text-sm text-red-600">{challanErr}</p>}
      {challan && (
        <ChallanPrint
          challans={[challan]}
          school={{ name: feeSchoolName, address: null, phone: null }}
          onClose={() => setChallan(null)}
        />
      )}

      {pay && (
        <PaymentModal
          studentId={studentId} studentName={student.full_name} grNo={student.gr_no}
          enrollmentId={enrollment.enrollment_id} billMonthISO={pay.billMonthISO}
          defaultAmount={pay.defaultAmount} defaultNote={pay.note}
          olderUnpaidWarning={pay.month ? hasOlderUnpaid(pay.month) : false}
          onClose={() => setPay(null)} onDone={(r) => { setPay(null); refresh(); if (r) setReceipt(r) }}
        />
      )}
      {settle && (
        <SettleModal studentId={studentId} studentName={student.full_name} grNo={student.gr_no}
          balance={bal} canWaive={canApprove}
          onClose={() => setSettle(false)} onDone={(r) => { setSettle(false); refresh(); if (r) setReceipt(r) }} />
      )}
      {showDiscount && (
        <DiscountModal enrollmentId={enrollment.enrollment_id} gross={grossFee} canApprove={canApprove}
          onClose={() => setShowDiscount(false)} onDone={() => { setShowDiscount(false); refresh() }} />
      )}
      {defer && (
        <DeferModal label={defer.label} enrollmentId={enrollment.enrollment_id}
          invoiceId={defer.invoiceId} billMonthISO={defer.billMonthISO}
          onClose={() => setDefer(null)} onDone={() => { setDefer(null); refresh() }} />
      )}
      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
    </div>
  )
}

function MonthLine({
  row, enrollment, onPay, onDelay, onUndoDefer, onPrint,
}: {
  row: MonthRow; enrollment: EnrollmentInfo
  onPay: () => void; onDelay: () => void; onUndoDefer?: () => void
  /** Present only for a month that has actually been billed — there is no
   *  challan to reprint for a month the school has not issued one for. */
  onPrint?: () => void
}) {
  void enrollment
  const paidDate = row.invoice?.status === 'paid' ? row.invoice.due_date : null
  return (
    <div className="flex flex-wrap items-center gap-3 py-2.5">
      <div className="w-32 text-sm font-medium text-slate-700">{row.label}</div>
      <div className="flex-1 min-w-[8rem] text-sm">
        {row.state === 'paid' && <span className="text-emerald-600">✓ Paid {fmtPKR(row.charge)}{paidDate ? ` · due ${fmtDate(paidDate)}` : ''}</span>}
        {row.state === 'free' && <span className="text-emerald-600">✓ Free (Rs 0)</span>}
        {row.state === 'partial' && <span className="text-amber-700">Partial · {fmtPKR(row.charge - row.due)} of {fmtPKR(row.charge)} · {fmtPKR(row.due)} left</span>}
        {row.state === 'unpaid' && <span className="text-red-600">Unpaid · {fmtPKR(row.due)} due</span>}
        {row.state === 'unbilled' && <span className="text-slate-500">Not billed · {fmtPKR(row.due)} expected</span>}
        {row.state === 'deferred' && (
          <span className="text-sky-700">Deferred{row.invoice?.deferred_until ? ` until ${fmtDate(row.invoice.deferred_until)}` : ''} · {fmtPKR(row.due)} still owed{row.invoice?.defer_reason ? ` · ${row.invoice.defer_reason}` : ''}</span>
        )}
      </div>
      <div className="flex gap-2">
        {(row.state === 'unpaid' || row.state === 'partial' || row.state === 'unbilled') && (
          <>
            <button onClick={onPay} className="rounded bg-brand-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-brand-700">Mark paid</button>
            <button onClick={onDelay} className="rounded border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-slate-50">Delay</button>
          </>
        )}
        {row.state === 'deferred' && (
          <>
            <button onClick={onPay} className="rounded bg-brand-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-brand-700">Mark paid</button>
            {onUndoDefer && <button onClick={onUndoDefer} className="rounded border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-slate-50">Undo delay</button>}
          </>
        )}
        {/* Reprint. Deliberately available on PAID months too: a parent asking
            for a duplicate of a settled challan is routine, and the slip shows
            the payment against it. */}
        {onPrint && (
          <button onClick={onPrint} className="rounded border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-slate-50">Print challan</button>
        )}
      </div>
    </div>
  )
}

function PaymentModal({
  studentId, studentName, grNo, enrollmentId, billMonthISO, defaultAmount, defaultNote,
  olderUnpaidWarning, onClose, onDone,
}: {
  studentId: string; studentName: string; grNo: string | null; enrollmentId: string
  billMonthISO?: string; defaultAmount: number; defaultNote: string; olderUnpaidWarning: boolean
  onClose: () => void; onDone: (r: ReceiptData | null) => void
}) {
  const [amount, setAmount] = useState(defaultAmount > 0 ? String(defaultAmount) : '')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState(defaultNote)
  const [pending, setPending] = useState(false)
  const amt = Number(amount)

  const m = useMutation({
    mutationFn: async (): Promise<ReceiptData | null> => {
      if (billMonthISO) {
        await billStudentMonth(enrollmentId, billMonthISO, monthLast(ym(billMonthISO)))
      }
      const res = await recordPayment(studentId, amt, method, note || undefined, pending)
      if (pending) return null
      const bal = await getStudentBalance(studentId)
      return {
        receiptNo: res.receipt_no, studentName, grNo, amount: amt,
        method: PAYMENT_METHODS.find((x) => x.value === method)?.label ?? method,
        balanceAfter: bal, note: note || null,
      }
    },
    onSuccess: (r) => onDone(r),
  })

  return (
    <Modal title="Record payment" onClose={onClose}>
      <label className="block">
        <span className="text-sm text-slate-600">Amount received</span>
        <input type="number" min="1" step="1" autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} className={FIELD} />
      </label>
      <label className="mt-3 block">
        <span className="text-sm text-slate-600">Method</span>
        <select value={method} onChange={(e) => setMethod(e.target.value)} className={FIELD}>
          {PAYMENT_METHODS.map((x) => <option key={x.value} value={x.value}>{x.label}</option>)}
        </select>
      </label>
      <label className="mt-3 block">
        <span className="text-sm text-slate-600">Note</span>
        <input value={note} onChange={(e) => setNote(e.target.value)} className={FIELD} />
      </label>
      <label className="mt-3 flex items-center gap-2 text-sm text-slate-700">
        <input type="checkbox" className="h-4 w-4" checked={pending} onChange={(e) => setPending(e.target.checked)} />
        Not cleared yet (pending — e.g. bank challan). Won’t count until verified.
      </label>
      {olderUnpaidWarning && !pending && (
        <p className="mt-3 rounded bg-amber-50 p-2 text-xs text-amber-700">
          Older months are still unpaid — this payment clears the oldest dues first (standard accounting).
        </p>
      )}
      {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}
      <div className="mt-4 flex gap-2">
        <button onClick={() => m.mutate()} disabled={!(amt > 0) || m.isPending}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {m.isPending ? 'Saving…' : pending ? 'Record as pending' : 'Record & print receipt'}
        </button>
        <button onClick={onClose} className="rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Cancel</button>
      </div>
    </Modal>
  )
}

function SettleModal({
  studentId, studentName, grNo, balance, canWaive, onClose, onDone,
}: {
  studentId: string; studentName: string; grNo: string | null; balance: number; canWaive: boolean
  onClose: () => void; onDone: (r: ReceiptData | null) => void
}) {
  const [mode, setMode] = useState<'pay' | 'waive'>('pay')
  const [method, setMethod] = useState('cash')
  const [reason, setReason] = useState('')

  const m = useMutation({
    mutationFn: async (): Promise<ReceiptData | null> => {
      if (mode === 'pay') {
        const res = await recordPayment(studentId, balance, method, 'Full settlement')
        const bal = await getStudentBalance(studentId)
        return {
          receiptNo: res.receipt_no, studentName, grNo, amount: balance,
          method: PAYMENT_METHODS.find((x) => x.value === method)?.label ?? method,
          balanceAfter: bal, note: 'Full settlement',
        }
      }
      await addAdjustment(studentId, -balance, reason.trim())
      return null
    },
    onSuccess: (r) => onDone(r),
  })

  return (
    <Modal title="Settle balance" onClose={onClose}>
      <p className="text-sm text-slate-600">Outstanding balance: <span className="font-semibold text-slate-800">{fmtPKR(balance)}</span></p>
      <div className="mt-3 flex gap-2">
        <button onClick={() => setMode('pay')} className={`flex-1 rounded border px-3 py-2 text-sm ${mode === 'pay' ? 'border-brand-600 bg-brand-50 text-brand-700' : 'border-slate-300 text-slate-600'}`}>Received full payment</button>
        <button onClick={() => setMode('waive')} disabled={!canWaive}
          className={`flex-1 rounded border px-3 py-2 text-sm disabled:opacity-40 ${mode === 'waive' ? 'border-brand-600 bg-brand-50 text-brand-700' : 'border-slate-300 text-slate-600'}`}>Waive outstanding</button>
      </div>
      {mode === 'pay' ? (
        <label className="mt-3 block">
          <span className="text-sm text-slate-600">Method</span>
          <select value={method} onChange={(e) => setMethod(e.target.value)} className={FIELD}>
            {PAYMENT_METHODS.map((x) => <option key={x.value} value={x.value}>{x.label}</option>)}
          </select>
        </label>
      ) : (
        <>
          <label className="mt-3 block">
            <span className="text-sm text-slate-600">Reason for waiving (required)</span>
            <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. hardship — owner approved" />
          </label>
          <p className="mt-2 text-xs text-amber-600">A waiver writes off what the family owes — it is not income and won’t appear in collections. Owner/principal only.</p>
        </>
      )}
      {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}
      <div className="mt-4 flex gap-2">
        <button onClick={() => m.mutate()} disabled={m.isPending || (mode === 'waive' && reason.trim() === '')}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {m.isPending ? 'Saving…' : mode === 'pay' ? 'Record full payment' : 'Waive balance'}
        </button>
        <button onClick={onClose} className="rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Cancel</button>
      </div>
    </Modal>
  )
}

function DiscountModal({
  enrollmentId, gross, canApprove, onClose, onDone,
}: { enrollmentId: string; gross: number; canApprove: boolean; onClose: () => void; onDone: () => void }) {
  const [type, setType] = useState('sibling')
  const [amount, setAmount] = useState('')
  const [isPercent, setIsPercent] = useState(true)
  const [reason, setReason] = useState('')

  const m = useMutation({
    mutationFn: async (free: boolean) => {
      const t = free ? 'scholarship' : type
      const amt = free ? 100 : Number(amount)
      const pct = free ? true : isPercent
      const rsn = free ? (reason.trim() || 'Full scholarship') : reason.trim()
      const id = await addDiscount(enrollmentId, t, amt, pct, rsn)
      if (canApprove) await setDiscountStatus(id, 'approved')
    },
    onSuccess: onDone,
  })

  const flatTooBig = !isPercent && gross > 0 && Number(amount) > gross
  const pctTooBig = isPercent && Number(amount) > 100

  return (
    <Modal title="Discount on fee" onClose={onClose}>
      <p className="text-sm text-slate-600">
        Monthly fee before discount: <span className="font-medium text-slate-800">{fmtPKR(gross)}</span>.
        {canApprove ? ' As owner/principal this applies immediately.' : ' This is proposed and applies once approved.'}
      </p>
      <div className="mt-3 grid grid-cols-2 gap-2">
        <label className="block"><span className="text-sm text-slate-600">Type</span>
          <select value={type} onChange={(e) => setType(e.target.value)} className={FIELD}>
            {DISCOUNT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
        </label>
        <label className="block"><span className="text-sm text-slate-600">Kind</span>
          <select value={isPercent ? 'pct' : 'flat'} onChange={(e) => setIsPercent(e.target.value === 'pct')} className={FIELD}>
            <option value="pct">% of fee</option>
            <option value="flat">Flat Rs</option>
          </select>
        </label>
        <label className="block"><span className="text-sm text-slate-600">Amount</span>
          <input type="number" min="1" value={amount} onChange={(e) => setAmount(e.target.value)} className={FIELD} />
        </label>
        <label className="block"><span className="text-sm text-slate-600">Reason</span>
          <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. two siblings" />
        </label>
      </div>
      {flatTooBig && <p className="mt-2 text-sm text-amber-600">A flat discount can’t exceed the monthly fee ({fmtPKR(gross)}). Use “Make free” for a full waiver.</p>}
      {pctTooBig && <p className="mt-2 text-sm text-amber-600">A percentage discount can’t exceed 100%.</p>}
      {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}
      <div className="mt-4 flex flex-wrap gap-2">
        <button onClick={() => m.mutate(false)} disabled={!(Number(amount) > 0) || flatTooBig || pctTooBig || m.isPending}
          className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {m.isPending ? 'Saving…' : canApprove ? 'Apply discount' : 'Propose discount'}
        </button>
        <button onClick={() => m.mutate(true)} disabled={m.isPending}
          className="rounded border border-emerald-300 px-4 py-2 text-sm font-medium text-emerald-700 hover:bg-emerald-50 disabled:opacity-60">
          Make free (100% scholarship)
        </button>
      </div>
    </Modal>
  )
}

function DeferModal({
  label, enrollmentId, invoiceId, billMonthISO, onClose, onDone,
}: { label: string; enrollmentId: string; invoiceId?: string; billMonthISO?: string; onClose: () => void; onDone: () => void }) {
  const [until, setUntil] = useState('')
  const [reason, setReason] = useState('')
  const m = useMutation({
    mutationFn: async () => {
      let id = invoiceId
      if (!id && billMonthISO) id = await billStudentMonth(enrollmentId, billMonthISO, monthLast(ym(billMonthISO)))
      if (!id) throw new Error('Nothing to defer')
      await deferInvoice(id, until || null, reason.trim())
    },
    onSuccess: onDone,
  })
  return (
    <Modal title={`Delay ${label}`} onClose={onClose}>
      <p className="text-sm text-slate-600">The family still owes this month — the reminder is paused and the reason is logged.</p>
      <label className="mt-3 block">
        <span className="text-sm text-slate-600">Pay by (optional)</span>
        <input type="date" value={until} onChange={(e) => setUntil(e.target.value)} className={FIELD} />
      </label>
      <label className="mt-3 block">
        <span className="text-sm text-slate-600">Reason</span>
        <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. father’s salary delayed" />
      </label>
      {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}
      <div className="mt-4 flex gap-2">
        <button onClick={() => m.mutate()} disabled={m.isPending}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {m.isPending ? 'Saving…' : 'Mark as delayed'}
        </button>
        <button onClick={onClose} className="rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Cancel</button>
      </div>
    </Modal>
  )
}

// =============================================================================
// Attendance & Tests tab
// =============================================================================
function AttendanceTestsTab({ student, enrollment }: { student: Student; enrollment: EnrollmentInfo }) {
  const months = useMemo(() => {
    const startISO = enrollment.session_starts ?? student.admission_date ?? todayISO()
    const todayYM = ym(todayISO())
    const endYM = enrollment.session_ends ? (ym(enrollment.session_ends) < todayYM ? ym(enrollment.session_ends) : todayYM) : todayYM
    let startYM = ym(startISO)
    if (startYM > endYM) startYM = endYM
    return monthsRange(startYM, endYM)
  }, [enrollment, student.admission_date])
  const [month, setMonth] = useState(ym(todayISO()))
  const effMonth = months.includes(month) ? month : (months[0] ?? ym(todayISO()))
  const isCurrent = effMonth === ym(todayISO())
  const [report, setReport] = useState<MonthReportData | null>(null)

  const summary = useQuery({
    queryKey: ['attSummary', enrollment.enrollment_id, effMonth],
    queryFn: () => attendanceSummary(enrollment.enrollment_id, monthFirst(effMonth), monthLast(effMonth)),
  })
  const tests = useQuery({
    queryKey: ['monthTests', enrollment.enrollment_id, effMonth],
    queryFn: () => getStudentMonthTests(enrollment.enrollment_id, monthFirst(effMonth)),
  })

  async function openReport() {
    const days = await getStudentMonthAttendance(enrollment.enrollment_id, effMonth)
    setReport({
      studentName: student.full_name, grNo: student.gr_no,
      className: enrollment.class_name, sectionName: enrollment.section_name, rollNo: enrollment.roll_no,
      monthLabel: monthLabel(effMonth), summary: summary.data ?? null, tests: tests.data ?? [], days,
    })
  }

  const d = summary.data

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <span className="text-sm text-slate-500">Session {enrollment.session_name}</span>
          <select value={effMonth} onChange={(e) => setMonth(e.target.value)}
            className="rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
            {months.map((m) => <option key={m} value={m}>{monthLabel(m)}{m === ym(todayISO()) ? ' (current)' : ''}</option>)}
          </select>
        </div>
        <button onClick={openReport} className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50">
          Save month PDF
        </button>
      </div>

      {/* Attendance stats for the month */}
      <div>
        <div className="flex flex-wrap items-baseline gap-2">
          <div className="text-3xl font-semibold text-slate-800">{d?.present_pct == null ? '—' : `${d.present_pct}%`}</div>
          <div className="text-sm text-slate-500">
            present over {d?.marked_days ?? 0} marked day{(d?.marked_days ?? 0) === 1 ? '' : 's'} · {monthLabel(effMonth)}{isCurrent ? ' (so far)' : ''}
          </div>
        </div>
        <div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-5">
          {ATTENDANCE_STATUSES.map((st) => (
            <div key={st.value} className="rounded-lg bg-white p-3 text-center shadow-sm ring-1 ring-slate-200">
              <div className="text-2xl font-semibold text-slate-800">{(d as any)?.[st.value] ?? 0}</div>
              <div className="text-xs text-slate-500">{st.label}</div>
            </div>
          ))}
        </div>
      </div>

      {/* Tests this month */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="text-xs uppercase tracking-wide text-slate-500">Tests in {monthLabel(effMonth)}</div>
        {tests.isLoading ? <p className="mt-2 text-sm text-slate-400">…</p> : (tests.data?.length ?? 0) === 0 ? (
          <p className="mt-2 text-sm text-slate-400">No class tests recorded this month.</p>
        ) : (
          <table className="mt-2 w-full text-sm">
            <thead className="text-left text-xs text-slate-400">
              <tr><th className="py-1">Test</th><th>Date</th><th>Marks</th><th>Class avg</th><th>Result</th></tr>
            </thead>
            <tbody>
              {tests.data?.map((t) => <TestRow key={t.assessment_id} t={t} />)}
            </tbody>
          </table>
        )}
      </div>

      {report && <StudentMonthReport data={report} onClose={() => setReport(null)} />}
    </div>
  )
}

function TestRow({ t }: { t: MonthTestRow }) {
  const marksText = t.is_absent ? 'Absent' : t.marks == null ? '—' : `${t.marks} / ${t.max_marks}`
  return (
    <tr className="border-t border-slate-100">
      <td className="py-1.5">{t.title}{t.subject_name ? <span className="text-slate-400"> · {t.subject_name}</span> : ''}</td>
      <td>{fmtDate(t.assessment_date)}</td>
      <td>{marksText}</td>
      <td className="text-slate-500">{t.class_avg == null ? '—' : `${t.class_avg} / ${t.max_marks}`}</td>
      <td>
        {t.is_absent ? <span className="text-slate-400">—</span>
          : t.marks == null ? <span className="text-slate-400">Not marked</span>
          : t.passed ? <span className="text-emerald-600">Pass</span>
          : <span className="text-red-600">Fail</span>}
      </td>
    </tr>
  )
}

// ---- Printable per-student monthly report (uses the global #report print CSS) ----
interface MonthReportData {
  studentName: string; grNo: string | null; className: string; sectionName: string | null; rollNo: string | null
  monthLabel: string
  summary: { present: number; absent: number; leave: number; late: number; half_day: number; marked_days: number; present_pct: number | null } | null
  tests: MonthTestRow[]
  days: { attendance_date: string; status: string }[]
}
function StudentMonthReport({ data, onClose }: { data: MonthReportData; onClose: () => void }) {
  const schoolName = useSchoolName()
  const d = data.summary
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-3xl rounded-lg bg-white p-6 shadow-lg print:max-w-none print:shadow-none" id="report">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{schoolName}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Monthly Attendance &amp; Tests · {data.monthLabel}</div>
        </div>
        <div className="mt-3 flex flex-wrap justify-between gap-2 text-sm text-slate-700">
          <span><span className="text-slate-500">Student:</span> {data.studentName}{data.grNo ? ` · ${data.grNo}` : ''}</span>
          <span><span className="text-slate-500">Class:</span> {data.className}{data.sectionName ? ` (${data.sectionName})` : ''}{data.rollNo ? ` · Roll ${data.rollNo}` : ''}</span>
        </div>

        <div className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Attendance</div>
        <div className="mt-1 text-sm text-slate-700">
          {d?.present_pct == null ? '—' : `${d.present_pct}% present`} over {d?.marked_days ?? 0} marked days ·
          {' '}P {d?.present ?? 0} · A {d?.absent ?? 0} · L {d?.leave ?? 0} · Lt {d?.late ?? 0} · ½ {d?.half_day ?? 0}
        </div>

        <div className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Tests</div>
        {data.tests.length === 0 ? <p className="mt-1 text-sm text-slate-400">No tests this month.</p> : (
          <table className="mt-1 w-full border-collapse text-sm">
            <thead><tr className="border-y border-slate-300 text-left text-xs uppercase tracking-wide text-slate-500">
              <th className="py-1 pr-2">Test</th><th className="py-1 pr-2">Date</th><th className="py-1 pr-2">Marks</th><th className="py-1 pr-2">Class avg</th><th className="py-1">Result</th>
            </tr></thead>
            <tbody>
              {data.tests.map((t) => (
                <tr key={t.assessment_id} className="border-b border-slate-100">
                  <td className="py-1 pr-2">{t.title}{t.subject_name ? ` · ${t.subject_name}` : ''}</td>
                  <td className="py-1 pr-2">{fmtDate(t.assessment_date)}</td>
                  <td className="py-1 pr-2">{t.is_absent ? 'Absent' : t.marks == null ? '—' : `${t.marks}/${t.max_marks}`}</td>
                  <td className="py-1 pr-2">{t.class_avg == null ? '—' : `${t.class_avg}/${t.max_marks}`}</td>
                  <td className="py-1">{t.is_absent ? '—' : t.marks == null ? '—' : t.passed ? 'Pass' : 'Fail'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        <div className="mt-4 text-xs font-semibold uppercase tracking-wide text-slate-500">Daily attendance</div>
        {data.days.length === 0 ? <p className="mt-1 text-sm text-slate-400">No attendance marked this month.</p> : (
          <div className="mt-1 grid grid-cols-2 gap-x-6 gap-y-0.5 text-sm sm:grid-cols-3">
            {data.days.map((day) => (
              <div key={day.attendance_date} className="flex justify-between border-b border-slate-100 py-0.5">
                <span className="text-slate-600">{fmtDate(day.attendance_date)}</span>
                <span className="font-medium text-slate-800">{ATTENDANCE_SHORT[day.status] ?? day.status}</span>
              </div>
            ))}
          </div>
        )}

        <div className="mt-6 text-center text-[10px] text-slate-400">Computer-generated report.</div>
        <div className="mt-5 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print / Save PDF</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

// ---- small shared bits ----
function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: React.ReactNode }) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4" onMouseDown={onClose}>
      <div className="mt-16 w-full max-w-md rounded-lg bg-white p-5 shadow-lg" onMouseDown={(e) => e.stopPropagation()}>
        <div className="text-base font-semibold text-slate-800">{title}</div>
        <div className="mt-3">{children}</div>
      </div>
    </div>
  )
}
function DiscountStatusPill({ status }: { status: string }) {
  const tone: Record<string, string> = {
    pending: 'bg-amber-100 text-amber-700', approved: 'bg-emerald-100 text-emerald-700',
    rejected: 'bg-slate-200 text-slate-600', revoked: 'bg-red-100 text-red-700',
  }
  return <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone[status] ?? 'bg-slate-100 text-slate-600'}`}>{status}</span>
}
function PaymentStatusPill({ status }: { status: string }) {
  const tone: Record<string, string> = {
    verified: 'bg-emerald-100 text-emerald-700', pending: 'bg-amber-100 text-amber-700', cancelled: 'bg-slate-200 text-slate-500',
  }
  return <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone[status] ?? 'bg-slate-100 text-slate-600'}`}>{PAYMENT_STATUS_LABELS[status] ?? status}</span>
}
function L({ label, wide, children }: { label: string; wide?: boolean; children: React.ReactNode }) {
  return <label className={`block ${wide ? 'sm:col-span-2' : ''}`}><span className="text-sm text-slate-600">{label}</span>{children}</label>
}
function Info({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="flex justify-between gap-4">
      <dt className="text-slate-500">{label}</dt>
      <dd className="text-right text-slate-700">{value || '—'}</dd>
    </div>
  )
}

/**
 * Says out loud whether two children actually bill together.
 *
 * This exists because the old panel showed "Qabi e Momin · Brother" and stopped
 * there, which read as "these two are one family" while the billing engine had
 * them completely separate — the fees never pooled and nobody could tell from
 * looking. The relationship and the money are two different facts, so the panel
 * now states the money one, and offers the fix when they disagree.
 */
function FamilyState({ mine, theirs, canEdit, pending, onJoin }: {
  mine: string | null | undefined
  theirs: string | null
  canEdit: boolean
  pending: boolean
  onJoin: () => void
}) {
  // Still loading, or a student with no family at all: say nothing rather than
  // claim something false.
  if (!mine || !theirs) return null

  if (mine === theirs) {
    return (
      <span className="mt-0.5 block text-xs text-money-700">
        ✓ Fees collect together
      </span>
    )
  }

  return (
    <span className="mt-0.5 flex flex-wrap items-center gap-2 text-xs">
      <span className="text-amber-700">Bills separately</span>
      {canEdit && (
        <button type="button" onClick={onJoin} disabled={pending}
          className="rounded border border-amber-300 bg-amber-50 px-1.5 py-0.5 font-medium text-amber-800 hover:bg-amber-100 disabled:opacity-50">
          {pending ? 'Joining…' : 'Put in one family'}
        </button>
      )}
    </span>
  )
}

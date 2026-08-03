import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  getStudent, getStudentEnrollments, getGuardians, updateStudent, setStudentStatus,
  getStudentBalance, getStudentInvoices, getStudentPayments, attendanceSummary, getSiblings,
  type StudentProfile as Student,
} from '@/lib/db'
import {
  GENDERS, STUDENT_STATUS_LABELS, INVOICE_STATUS_LABELS, PAYMENT_METHODS, ATTENDANCE_STATUSES,
} from '@/lib/constants'
import { fmtPKR, fmtDate, waLink, todayISO } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, ADMIN_ROLES } from '@/auth/roles'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const TABS = ['Overview', 'Fees', 'Attendance'] as const
type Tab = (typeof TABS)[number]

export function StudentProfile({ studentId, onBack, onOpen }: { studentId: string; onBack: () => void; onOpen?: (id: string) => void }) {
  const { profile } = useAuth()
  const role = profile?.role
  const canEdit = !!role && ADMIN_ROLES.includes(role) && role !== 'readonly' && role !== 'accountant'
  const canStatus = !!role && APPROVER_ROLES.includes(role)

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
        {tab === 'Fees' && <FeesTab studentId={studentId} />}
        {tab === 'Attendance' && (
          cur
            ? <AttendanceTab enrollmentId={cur.enrollment_id} from={cur.session_starts ?? '2000-01-01'} to={cur.session_ends ?? todayISO()} sessionName={cur.session_name} />
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
  enrollments: { session_name: string; class_name: string; section_name: string | null; roll_no: string | null; status: string }[]
  canEdit: boolean
  onOpen?: (id: string) => void
}) {
  const siblings = useQuery({ queryKey: ['siblings', student.id], queryFn: () => getSiblings(student.id) })
  const qc = useQueryClient()
  const [editing, setEditing] = useState(false)
  const [f, setF] = useState(student)
  // Empty strings must become null: gender (enum) and dob (date) reject '' —
  // and null keeps the other bio fields clean rather than storing blanks.
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
          <div className="text-xs uppercase tracking-wide text-slate-500">Guardians</div>
          {guardians.length === 0 ? (
            <p className="mt-2 text-sm text-slate-400">None recorded.</p>
          ) : (
            <ul className="mt-2 space-y-1.5 text-sm">
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
          {siblings.isLoading ? (
            <p className="mt-2 text-sm text-slate-400">…</p>
          ) : (siblings.data?.length ?? 0) === 0 ? (
            <p className="mt-2 text-sm text-slate-400">No siblings detected (matched on father’s name).</p>
          ) : (
            <ul className="mt-2 space-y-1.5 text-sm">
              {siblings.data?.map((sib) => (
                <li key={sib.id}>
                  <button onClick={() => onOpen?.(sib.id)} disabled={!onOpen}
                    className="text-left text-slate-700 hover:text-brand-700 hover:underline disabled:cursor-default disabled:no-underline">
                    {sib.full_name}{sib.gr_no ? ` · ${sib.gr_no}` : ''}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  )
}

function FeesTab({ studentId }: { studentId: string }) {
  const balance = useQuery({ queryKey: ['balance', studentId], queryFn: () => getStudentBalance(studentId) })
  const invoices = useQuery({ queryKey: ['invoices', studentId], queryFn: () => getStudentInvoices(studentId) })
  const payments = useQuery({ queryKey: ['payments', studentId], queryFn: () => getStudentPayments(studentId) })
  return (
    <div className="space-y-4">
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="text-xs uppercase tracking-wide text-slate-500">Current balance</div>
        <div className={`mt-1 text-2xl font-semibold ${(balance.data ?? 0) > 0 ? 'text-red-600' : 'text-emerald-600'}`}>
          {balance.isLoading ? '…' : fmtPKR(balance.data ?? 0)}
        </div>
      </div>
      <div className="grid gap-4 md:grid-cols-2">
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Invoices</div>
          <table className="mt-2 w-full text-sm">
            <thead className="text-left text-xs text-slate-400"><tr><th className="py-1">Month</th><th>Charge</th><th>Due</th><th>Status</th></tr></thead>
            <tbody>
              {invoices.data?.map((i) => (
                <tr key={i.invoice_id} className="border-t border-slate-100">
                  <td className="py-1.5">{fmtDate(i.period_month)}</td>
                  <td>{fmtPKR(i.charge)}</td>
                  <td className={i.charge - i.allocated > 0 ? 'text-red-600' : ''}>{fmtPKR(i.charge - i.allocated)}</td>
                  <td>{INVOICE_STATUS_LABELS[i.status] ?? i.status}</td>
                </tr>
              ))}
              {invoices.data?.length === 0 && <tr><td colSpan={4} className="py-3 text-slate-400">No invoices.</td></tr>}
            </tbody>
          </table>
        </div>
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Payments</div>
          <table className="mt-2 w-full text-sm">
            <thead className="text-left text-xs text-slate-400"><tr><th className="py-1">Receipt</th><th>Date</th><th>Amount</th><th>Method</th></tr></thead>
            <tbody>
              {payments.data?.map((p) => (
                <tr key={p.id} className="border-t border-slate-100">
                  <td className="py-1.5">#{p.receipt_no}</td>
                  <td>{fmtDate(p.created_at)}</td>
                  <td className={p.amount < 0 ? 'text-red-600' : ''}>{fmtPKR(p.amount)}</td>
                  <td>{PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method}</td>
                </tr>
              ))}
              {payments.data?.length === 0 && <tr><td colSpan={4} className="py-3 text-slate-400">No payments.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}

function AttendanceTab({ enrollmentId, from, to, sessionName }: { enrollmentId: string; from: string; to: string; sessionName: string }) {
  const summary = useQuery({ queryKey: ['attSummary', enrollmentId, from, to], queryFn: () => attendanceSummary(enrollmentId, from, to) })
  if (summary.isLoading) return <p className="text-sm text-slate-500">Loading…</p>
  if (summary.isError) return <p className="text-sm text-red-600">{(summary.error as Error).message}</p>
  const d = summary.data!
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-baseline gap-2">
        <div className="text-3xl font-semibold text-slate-800">{d.present_pct == null ? '—' : `${d.present_pct}%`}</div>
        <div className="text-sm text-slate-500">present over {d.marked_days} marked day{d.marked_days === 1 ? '' : 's'} · session {sessionName}</div>
      </div>
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">
        {ATTENDANCE_STATUSES.map((st) => (
          <div key={st.value} className="rounded-lg bg-white p-3 text-center shadow-sm ring-1 ring-slate-200">
            <div className="text-2xl font-semibold text-slate-800">{(d as any)[st.value] ?? 0}</div>
            <div className="text-xs text-slate-500">{st.label}</div>
          </div>
        ))}
      </div>
    </div>
  )
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

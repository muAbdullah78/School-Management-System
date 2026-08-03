import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, getCurrentEnrollment, addDiscount, listDiscounts, setDiscountStatus,
  type StudentRow,
} from '@/lib/db'
import { DISCOUNT_TYPES, DISCOUNT_STATUS_LABELS } from '@/lib/constants'
import { fmtPKR } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, type Role } from '@/auth/roles'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const STATUS_TONE: Record<string, string> = {
  pending: 'bg-amber-100 text-amber-700', approved: 'bg-emerald-100 text-emerald-700',
  rejected: 'bg-slate-200 text-slate-600', revoked: 'bg-red-100 text-red-700',
}

export function Discounts() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canApprove = !!profile && APPROVER_ROLES.includes(profile.role as Role)

  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const [type, setType] = useState('sibling')
  const [amount, setAmount] = useState('')
  const [isPercent, setIsPercent] = useState(true)
  const [reason, setReason] = useState('')

  const results = useQuery({ queryKey: ['discStudentSearch', term], queryFn: () => searchStudents(term), enabled: term.trim().length >= 2 && !student })
  const enrollment = useQuery({ queryKey: ['currentEnrollment', student?.id], queryFn: () => getCurrentEnrollment(student!.id), enabled: !!student })
  const register = useQuery({ queryKey: ['discounts'], queryFn: listDiscounts })

  const add = useMutation({
    mutationFn: () => addDiscount(enrollment.data!.enrollment_id, type, Number(amount), isPercent, reason.trim()),
    onSuccess: () => { setAmount(''); setReason(''); qc.invalidateQueries({ queryKey: ['discounts'] }) },
  })
  const setStatus = useMutation({
    mutationFn: (v: { id: string; status: string }) => setDiscountStatus(v.id, v.status),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['discounts'] }),
  })

  const ready = !!enrollment.data && Number(amount) > 0

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Propose a discount</div>
        <p className="mt-1 text-sm text-slate-600">
          A discount is proposed here, then <span className="font-medium">approved by the owner or principal</span>. Once
          approved it’s applied automatically on the next challan run for that student.
        </p>

        {!student ? (
          <div className="mt-3 max-w-md">
            <input autoFocus value={term} onChange={(e) => setTerm(e.target.value)} placeholder="Search student by name or GR…" className={FIELD} />
            <div className="mt-2 divide-y divide-slate-100 rounded border border-slate-200">
              {results.data?.length === 0 && term.trim().length >= 2 && <div className="p-2 text-sm text-slate-500">No students found.</div>}
              {results.data?.map((s) => (
                <button key={s.id} onClick={() => setStudent(s)} className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50">
                  <span className="font-medium text-slate-800">{s.full_name}</span>{s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <div className="mt-3">
            <div className="flex items-center justify-between">
              <div className="text-sm text-slate-700">
                <span className="font-medium">{student.full_name}</span>{student.gr_no ? ` · ${student.gr_no}` : ''}
                {enrollment.data ? <span className="text-slate-500"> · {enrollment.data.class_name}{enrollment.data.section_name ? ` · ${enrollment.data.section_name}` : ''}</span>
                  : enrollment.isFetched ? <span className="text-amber-600"> · not enrolled this session</span> : ''}
              </div>
              <button onClick={() => { setStudent(null); setTerm('') }} className="text-sm text-brand-700 hover:underline">Change</button>
            </div>
            <div className="mt-3 grid gap-3 sm:grid-cols-4">
              <label className="block"><span className="text-sm text-slate-600">Type</span>
                <select value={type} onChange={(e) => setType(e.target.value)} className={FIELD}>
                  {DISCOUNT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                </select>
              </label>
              <label className="block"><span className="text-sm text-slate-600">Amount</span>
                <input type="number" min="1" value={amount} onChange={(e) => setAmount(e.target.value)} className={FIELD} />
              </label>
              <label className="block"><span className="text-sm text-slate-600">Kind</span>
                <select value={isPercent ? 'pct' : 'flat'} onChange={(e) => setIsPercent(e.target.value === 'pct')} className={FIELD}>
                  <option value="pct">% of tuition</option>
                  <option value="flat">Flat Rs</option>
                </select>
              </label>
              <label className="block"><span className="text-sm text-slate-600">Reason</span>
                <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. two siblings" />
              </label>
            </div>
            {add.isError && <p className="mt-2 text-sm text-red-600">{(add.error as Error).message}</p>}
            <button onClick={() => add.mutate()} disabled={!ready || add.isPending}
              className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {add.isPending ? 'Submitting…' : 'Propose discount'}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Discount register</div>
        <div className="mt-2 overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr><th className="px-3 py-2">Student</th><th className="px-3 py-2">Class</th><th className="px-3 py-2">Type</th><th className="px-3 py-2">Value</th><th className="px-3 py-2">Reason</th><th className="px-3 py-2">Status</th><th className="px-3 py-2 w-40"></th></tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {register.data?.length === 0 && <tr><td colSpan={7} className="px-3 py-3 text-slate-500">No discounts yet.</td></tr>}
              {register.data?.map((d) => (
                <tr key={d.id}>
                  <td className="px-3 py-2 text-slate-800">{d.student_name ?? '—'}<span className="text-slate-400">{d.gr_no ? ` · ${d.gr_no}` : ''}</span></td>
                  <td className="px-3 py-2 text-slate-600">{d.class_name ?? '—'}</td>
                  <td className="px-3 py-2 text-slate-600">{DISCOUNT_TYPES.find((t) => t.value === d.type)?.label ?? d.type}</td>
                  <td className="px-3 py-2 text-slate-700">{d.is_percent ? `${d.amount}%` : fmtPKR(d.amount)}</td>
                  <td className="px-3 py-2 text-slate-500">{d.reason ?? '—'}</td>
                  <td className="px-3 py-2"><span className={`rounded px-2 py-0.5 text-xs font-medium ${STATUS_TONE[d.status] ?? ''}`}>{DISCOUNT_STATUS_LABELS[d.status] ?? d.status}</span></td>
                  <td className="px-3 py-2 text-right">
                    {canApprove && d.status === 'pending' && (
                      <>
                        <button onClick={() => setStatus.mutate({ id: d.id, status: 'approved' })} className="mr-2 text-sm text-emerald-700 hover:underline">Approve</button>
                        <button onClick={() => setStatus.mutate({ id: d.id, status: 'rejected' })} className="text-sm text-slate-500 hover:underline">Reject</button>
                      </>
                    )}
                    {canApprove && d.status === 'approved' && (
                      <button onClick={() => { if (confirm('Revoke this approved discount? It won’t apply to future challans.')) setStatus.mutate({ id: d.id, status: 'revoked' }) }}
                        className="text-sm text-red-600 hover:underline">Revoke</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {setStatus.isError && <p className="mt-2 text-sm text-red-600">{(setStatus.error as Error).message}</p>}
        {!canApprove && <p className="mt-2 text-xs text-slate-400">Only the owner or principal can approve or reject discounts.</p>}
      </div>
    </div>
  )
}

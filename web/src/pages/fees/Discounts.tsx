/**
 * The school's concessions, in one list.
 *
 * WHAT WAS WRONG WITH THIS SCREEN, in the order it bit:
 *
 *   1. IT READ THE MODEL 0138 REPLACED. The register came straight out of
 *      PostgREST with `enrollments!inner(...)`, and enrollment_id is nullable
 *      and meaningless now. A concession granted to a child with no active
 *      enrolment DISAPPEARED from this list while still coming off every
 *      challan, and the class beside every row was the class of the enrolment
 *      the row was recorded against, which after one rollover is last year's.
 *
 *   2. NO DATES AND NO IN-FORCE STATE. A discount has covered a range of months
 *      since 0138 and this showed neither end of it. A waiver that stopped in
 *      March still read "approved" with a Revoke button beside it, and the one
 *      question a head asks of this list, "what am I giving away this month",
 *      could not be asked at all.
 *
 *   3. IT REFUSED A CHILD WITH NO ENROLMENT. The Propose button was disabled
 *      until getCurrentEnrollment returned a row, which is a stricter rule than
 *      the database has: a discount belongs to the CHILD now, precisely so it
 *      survives the gap between two school years.
 *
 *   4. IT PROMISED SOMETHING THAT NO LONGER HAPPENS. "Applied automatically on
 *      the next challan run for that student" was true when a human pressed
 *      Generate Challans. 0139 bills the month by itself and 0138 reprices the
 *      challans already raised, so approving a discount changes what is owed
 *      now, not at some future run.
 *
 *   5. Revoke went through `confirm()`. Once a browser has been told to stop
 *      showing dialogs from a page, confirm() returns false for ever and the
 *      button silently stops working. scripts/check-no-browser-dialogs.py
 *      existed to prevent exactly this and matched only `window.confirm`, so it
 *      never saw a bare one.
 *
 * Granting and editing one concession is the CHILD'S page, reached from here.
 * Two editors for one thing is how they drift apart, and the child's page is
 * where the fee, the statement and the months it has covered already are.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useNavigate } from 'react-router-dom'
import {
  searchStudents, getCurrentEnrollment, addDiscount, listDiscountRegister, setDiscountStatus,
  type StudentRow, type DiscountRow,
} from '@/lib/db'
import { DISCOUNT_TYPES, DISCOUNT_STATUS_LABELS } from '@/lib/constants'
import { fmtPKR, fmtMonth } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, type Role } from '@/auth/roles'
import { AskDialog } from '@/components/AskDialog'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const STATUS_TONE: Record<string, string> = {
  pending: 'bg-amber-100 text-amber-700', approved: 'bg-emerald-100 text-emerald-700',
  rejected: 'bg-slate-200 text-slate-600', revoked: 'bg-red-100 text-red-700',
}

function thisMonthISO(): string {
  // Karachi, not the browser. A machine set to UTC crosses into the next month
  // five hours after Pakistan does, and this box decides which month a
  // concession starts in.
  const k = new Date(Date.now() + 5 * 60 * 60 * 1000)
  return `${k.getUTCFullYear()}-${String(k.getUTCMonth() + 1).padStart(2, '0')}`
}

export function Discounts() {
  const qc = useQueryClient()
  const navigate = useNavigate()
  const { profile } = useAuth()
  const canApprove = !!profile && APPROVER_ROLES.includes(profile.role as Role)

  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const [type, setType] = useState('sibling')
  const [amount, setAmount] = useState('')
  const [isPercent, setIsPercent] = useState(true)
  const [reason, setReason] = useState('')
  const [startsOn, setStartsOn] = useState(thisMonthISO())
  const [endsOn, setEndsOn] = useState('')
  const [liveOnly, setLiveOnly] = useState(false)
  const [revoking, setRevoking] = useState<DiscountRow | null>(null)

  const results = useQuery({
    queryKey: ['discStudentSearch', term],
    queryFn: () => searchStudents(term),
    enabled: term.trim().length >= 2 && !student,
  })
  // Shown, not required. The button used to be disabled until this returned a
  // row, which refused a discount to exactly the child 0138 exists to protect:
  // one between two school years.
  const enrollment = useQuery({
    queryKey: ['currentEnrollment', student?.id],
    queryFn: () => getCurrentEnrollment(student!.id),
    enabled: !!student,
  })
  const register = useQuery({
    queryKey: ['discountRegister', liveOnly],
    queryFn: () => listDiscountRegister(liveOnly),
  })

  function refresh() {
    qc.invalidateQueries({ queryKey: ['discountRegister'] })
    qc.invalidateQueries({ queryKey: ['studentDiscounts'] })
    qc.invalidateQueries({ queryKey: ['monthlyFee'] })
    // Approving one reprices challans, so every fee figure on screen moved.
    qc.invalidateQueries({ queryKey: ['familySheet'] })
    qc.invalidateQueries({ queryKey: ['feesMonth'] })
    qc.invalidateQueries({ queryKey: ['feesMonthPupils'] })
    qc.invalidateQueries({ queryKey: ['studentFeeState'] })
  }

  const add = useMutation({
    mutationFn: async () => {
      const id = await addDiscount(
        student!.id, type, Number(amount), isPercent, reason.trim(),
        `${startsOn}-01`, endsOn ? `${endsOn}-01` : null,
      )
      // owner and principal are the only roles fn_add_discount admits, so in
      // practice this always runs. It is kept conditional rather than assumed,
      // because a role list is a thing that changes.
      if (canApprove) await setDiscountStatus(id, 'approved')
    },
    onSuccess: () => { setAmount(''); setReason(''); setEndsOn(''); refresh() },
  })
  const setStatus = useMutation({
    mutationFn: (v: { id: string; status: string }) => setDiscountStatus(v.id, v.status),
    onSuccess: () => { setRevoking(null); refresh() },
  })

  const endsBeforeStart = !!endsOn && endsOn < startsOn
  const pctTooBig = isPercent && Number(amount) > 100
  const ready = !!student && Number(amount) > 0 && !endsBeforeStart && !pctTooBig

  const rows = register.data ?? []
  const liveCount = rows.filter((d) => d.live).length

  return (
    <div className="space-y-6">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Give a discount</div>
        <p className="mt-1 text-sm text-slate-600">
          A concession belongs to the <span className="font-medium">child</span> and runs until
          somebody ends it, including into next school year. Approving one rewrites the
          challans already raised for the months it covers, except any month money has
          already been taken against.
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
                  : enrollment.isFetched ? <span className="text-amber-600"> · not enrolled this session, which does not stop a discount</span> : ''}
              </div>
              <button onClick={() => { setStudent(null); setTerm('') }} className="text-sm text-brand-700 hover:underline">Change</button>
            </div>
            <div className="mt-3 grid gap-3 sm:grid-cols-3 lg:grid-cols-6">
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
                  <option value="pct">% of fee</option>
                  <option value="flat">Flat Rs</option>
                </select>
              </label>
              <label className="block"><span className="text-sm text-slate-600">Starts from</span>
                <input type="month" value={startsOn} onChange={(e) => setStartsOn(e.target.value)} className={FIELD} />
              </label>
              <label className="block"><span className="text-sm text-slate-600">Ends after</span>
                <input type="month" value={endsOn} onChange={(e) => setEndsOn(e.target.value)} className={FIELD} />
              </label>
              <label className="block"><span className="text-sm text-slate-600">Reason</span>
                <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. two siblings" />
              </label>
            </div>
            {pctTooBig && <p className="mt-2 text-sm text-amber-600">A percentage discount can’t be more than 100%.</p>}
            {endsBeforeStart && <p className="mt-2 text-sm text-amber-600">The end month can’t be before the month it starts in.</p>}
            {!endsOn && <p className="mt-2 text-xs text-slate-400">Leave the end month empty and it runs until somebody ends it.</p>}
            {add.isError && <p className="mt-2 text-sm text-red-600">{(add.error as Error).message}</p>}
            <button onClick={() => add.mutate()} disabled={!ready || add.isPending}
              className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {add.isPending ? 'Saving…' : canApprove ? 'Apply discount' : 'Propose discount'}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="flex flex-wrap items-center justify-between gap-2">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Discount register
            <span className="ml-2 font-normal normal-case tracking-normal text-slate-400">
              {liveCount} running this month
            </span>
          </div>
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input type="checkbox" checked={liveOnly} onChange={(e) => setLiveOnly(e.target.checked)} />
            Only the ones running this month
          </label>
        </div>
        <div className="mt-2 overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2">Student</th><th className="px-3 py-2">Class</th>
                <th className="px-3 py-2">Type</th><th className="px-3 py-2">Value</th>
                <th className="px-3 py-2">Months</th><th className="px-3 py-2">Reason</th>
                <th className="px-3 py-2">Status</th><th className="px-3 py-2 w-40"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {register.isLoading && <tr><td colSpan={8} className="px-3 py-3 text-slate-400">Loading…</td></tr>}
              {register.isError && <tr><td colSpan={8} className="px-3 py-3 text-red-600">{(register.error as Error).message}</td></tr>}
              {rows.length === 0 && !register.isLoading && (
                <tr><td colSpan={8} className="px-3 py-3 text-slate-500">
                  {liveOnly ? 'No discount is running this month.' : 'No discounts yet.'}
                </td></tr>
              )}
              {rows.map((d) => (
                <tr key={d.id}>
                  <td className="px-3 py-2">
                    {/* Opens the child, where the fee, the statement and the
                        months this has already covered are. */}
                    <button onClick={() => navigate(`/students?student=${d.student_id}`)}
                      className="text-left text-slate-800 hover:underline">
                      {d.student_name ?? '-'}
                    </button>
                    <span className="text-slate-400">{d.gr_no ? ` · ${d.gr_no}` : ''}</span>
                  </td>
                  <td className="px-3 py-2 text-slate-600">
                    {d.class_name ?? <span className="text-amber-600">not enrolled</span>}
                    {d.section_name ? ` · ${d.section_name}` : ''}
                  </td>
                  <td className="px-3 py-2 text-slate-600">{DISCOUNT_TYPES.find((t) => t.value === d.type)?.label ?? d.type}</td>
                  <td className="px-3 py-2 text-slate-700">{d.is_percent ? `${d.amount}%` : fmtPKR(d.amount)}</td>
                  <td className="whitespace-nowrap px-3 py-2 text-slate-600">
                    {fmtMonth(d.starts_on)}
                    {d.ends_on ? ` to ${fmtMonth(d.ends_on)}` : ' onwards'}
                  </td>
                  <td className="px-3 py-2 text-slate-500">{d.reason ?? '-'}</td>
                  <td className="whitespace-nowrap px-3 py-2">
                    {d.live && <span className="mr-1 rounded bg-emerald-100 px-2 py-0.5 text-xs font-medium text-emerald-700">In force</span>}
                    <span className={`rounded px-2 py-0.5 text-xs font-medium ${STATUS_TONE[d.status] ?? ''}`}>{DISCOUNT_STATUS_LABELS[d.status] ?? d.status}</span>
                  </td>
                  <td className="px-3 py-2 text-right">
                    {canApprove && d.status === 'pending' && (
                      <>
                        <button onClick={() => setStatus.mutate({ id: d.id, status: 'approved' })} className="mr-2 text-sm text-emerald-700 hover:underline">Approve</button>
                        <button onClick={() => setStatus.mutate({ id: d.id, status: 'rejected' })} className="text-sm text-slate-500 hover:underline">Reject</button>
                      </>
                    )}
                    {canApprove && d.status === 'approved' && (
                      <button onClick={() => setRevoking(d)} className="text-sm text-red-600 hover:underline">Revoke</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {setStatus.isError && <p className="mt-2 text-sm text-red-600">{(setStatus.error as Error).message}</p>}
        <p className="mt-2 text-xs text-slate-400">
          Anything waiting on a decision is at the top. Open a child to change the amount
          or the months, or to end a concession from a date rather than cancel it outright.
        </p>
        {!canApprove && <p className="mt-1 text-xs text-slate-400">Only the owner or principal can approve, reject or revoke a discount.</p>}
      </div>

      {/* NOT confirm(). Revoking a concession changes what a family is charged;
          a dialog a browser can switch off is not a confirmation. */}
      {revoking && (
        <AskDialog
          title="Revoke this discount?"
          intro={
            <>
              {DISCOUNT_TYPES.find((t) => t.value === revoking.type)?.label ?? revoking.type}
              {' · '}{revoking.is_percent ? `${revoking.amount}%` : fmtPKR(revoking.amount)}
              {' for '}{revoking.student_name ?? 'this student'}. It stops applying at once and
              the unpaid challans that carry it are rewritten at the full fee. Months already
              paid for are left as they are. To stop it from a future month instead, open the
              child and end it from there.
            </>
          }
          confirmLabel="Revoke it"
          tone="danger"
          busy={setStatus.isPending}
          error={setStatus.error ? (setStatus.error as Error).message : null}
          onCancel={() => setRevoking(null)}
          onSubmit={() => setStatus.mutate({ id: revoking.id, status: 'revoked' })}
        />
      )}
    </div>
  )
}

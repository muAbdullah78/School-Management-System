import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, issueCertificate, listCertificates, certificateReadiness,
  cancelCertificate, type StudentRow, type CertificateRow,
} from '@/lib/db'
import { CERT_TYPES, CERT_LABELS } from '@/lib/constants'
import { fmtDate, fmtPKR, todayISO } from '@/lib/format'
import { CertificatePrint, type CertificatePrintData } from './CertificatePrint'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { LoadError } from '@/components/ui'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const CONDUCTS = ['Excellent', 'Very Good', 'Good', 'Satisfactory']
const LEAVING_REASONS = [
  'Family relocation', 'Transfer to another school', 'Completed final class',
  'Financial reasons', 'Migration abroad', 'On parent’s request',
]

/** Turning a cert row into what the printer needs. One place, so the register
 *  and the just-issued document can never render differently. */
function toPrint(c: CertificateRow): CertificatePrintData {
  return {
    certType: c.cert_type, serialNo: c.serial_no, issuedOn: c.issued_on,
    data: c.data, photoPath: c.photo_path,
    isDuplicate: c.is_duplicate, originalSerialNo: c.original_serial_no,
    cancelledAt: c.cancelled_at,
  }
}

export function CertificatesPage() {
  const qc = useQueryClient()
  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const [certType, setCertType] = useState('leaving')
  const [dateOfLeaving, setDateOfLeaving] = useState(todayISO())
  const [reason, setReason] = useState('')
  const [purpose, setPurpose] = useState('')
  const [conduct, setConduct] = useState('Good')
  const [remarks, setRemarks] = useState('')
  const [override, setOverride] = useState(false)
  const [overrideReason, setOverrideReason] = useState('')
  const [print, setPrint] = useState<CertificatePrintData | null>(null)
  const [cancelling, setCancelling] = useState<CertificateRow | null>(null)
  const { profile } = useAuth()
  // Issuing a certificate takes a serial number that can never be reused, so an
  // observer does not get the form at all. Reprinting one already issued reads a
  // frozen snapshot and changes nothing, so that stays.
  const mayWrite = canWrite(profile?.role)
  // Releasing a leaving certificate over unpaid fees, and cancelling one issued
  // in error, are both decisions with consequences outside the school. A clerk
  // issues certificates all day; neither of these is clerical.
  const maySignOff = mayWrite && (profile?.role === 'owner' || profile?.role === 'principal')

  const results = useQuery({ queryKey: ['certStudentSearch', term], queryFn: () => searchStudents(term), enabled: term.trim().length >= 2 && !student })
  const register = useQuery({ queryKey: ['certificates'], queryFn: () => listCertificates(50) })

  // What the database will do BEFORE the clerk presses Issue. Without this the
  // dues refusal only appears as a red error after the attempt, which reads as a
  // fault in the software rather than as a condition to resolve.
  const ready = useQuery({
    queryKey: ['certReadiness', student?.id, certType],
    queryFn: () => certificateReadiness(student!.id, certType),
    enabled: !!student,
  })

  // A tick left switched on from a previous pupil must not silently release the
  // next one's certificate.
  useEffect(() => { setOverride(false); setOverrideReason('') }, [student?.id, certType])

  const issue = useMutation({
    mutationFn: () => {
      const data: Record<string, any> = {}
      if (remarks.trim()) data.remarks = remarks.trim()
      if (certType === 'leaving') { data.conduct = conduct }
      else if (certType === 'character') { data.conduct = conduct }
      else { if (purpose.trim()) data.purpose = purpose.trim() }
      return issueCertificate(certType, student!.id, data, {
        // Required by the database for a leaving certificate: issuing one records
        // the child as having left, so there is no way to produce one without
        // saying when and why.
        leavingOn: certType === 'leaving' ? dateOfLeaving : null,
        leavingReason: certType === 'leaving' ? reason.trim() || null : null,
        overrideDues: override,
        overrideReason: override ? overrideReason.trim() || null : null,
      })
    },
    onSuccess: async (res) => {
      const list = await listCertificates(50)
      qc.setQueryData(['certificates'], list)
      // The pupil's status and balance changed, so anything showing either is stale.
      qc.invalidateQueries({ queryKey: ['students'] })
      qc.invalidateQueries({ queryKey: ['certReadiness'] })
      const row = list.find((c) => c.id === res.id)
      if (row) setPrint(toPrint(row))
      setReason(''); setPurpose(''); setRemarks('')
      setOverride(false); setOverrideReason('')
    },
  })

  const cancel = useMutation({
    mutationFn: (v: { id: string; reason: string }) => cancelCertificate(v.id, v.reason),
    onSuccess: async () => {
      qc.setQueryData(['certificates'], await listCertificates(50))
      qc.invalidateQueries({ queryKey: ['certReadiness'] })
      setCancelling(null)
    },
  })

  function reset() { setStudent(null); setTerm('') }

  const needsConduct = certType === 'leaving' || certType === 'character'
  const needsPurpose = certType === 'bonafide' || certType === 'other'
  const r = ready.data
  const blocked = !!r?.blocked_by_dues && !override
  // The leaving date and reason are not optional extras — the database refuses
  // without them — so the button has to refuse too, rather than surfacing the
  // refusal as a database error.
  const missingLeaving = certType === 'leaving' && (!dateOfLeaving || !reason.trim())
  const overrideIncomplete = override && !overrideReason.trim()

  return (
    <div className="max-w-3xl">
      <h1 className="text-xl font-semibold text-slate-800">Certificates</h1>

      <LoadError of={[register, ready]} what="The certificate register" />

      {!mayWrite && <ObserverNotice what="certificates already issued" />}

      {/* Issue */}
      {mayWrite && (
      <div className="mt-4 rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Issue a certificate</div>

        {!student ? (
          <div className="mt-3">
            <label className="block max-w-md">
              <span className="text-sm text-slate-600">Search student by name or GR number</span>
              <input autoFocus value={term} onChange={(e) => setTerm(e.target.value)} className={FIELD} placeholder="e.g. Ahmed or GR-0001" />
            </label>
            <div className="mt-2 max-w-md divide-y divide-slate-100 rounded border border-slate-200">
              {results.data?.length === 0 && term.trim().length >= 2 && <div className="p-2 text-sm text-slate-500">No students found.</div>}
              {results.data?.map((s) => (
                <button key={s.id} onClick={() => setStudent(s)} className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50">
                  <span className="font-medium text-slate-800">{s.full_name}</span>
                  {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
                  {s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
                </button>
              ))}
            </div>
          </div>
        ) : (
          <div className="mt-3">
            <div className="flex items-center justify-between">
              <div className="text-sm text-slate-700"><span className="font-medium">{student.full_name}</span>{student.gr_no ? ` · ${student.gr_no}` : ''}</div>
              <button onClick={reset} className="text-sm text-brand-700 hover:underline">Change student</button>
            </div>
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <label className="block">
                <span className="text-sm text-slate-600">Certificate type</span>
                <select value={certType} onChange={(e) => setCertType(e.target.value)} className={FIELD}>
                  {CERT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
                </select>
              </label>
              {certType === 'leaving' && (
                <label className="block">
                  <span className="text-sm text-slate-600">Date of leaving <span className="text-red-500">*</span></span>
                  <input type="date" max={todayISO()} value={dateOfLeaving} onChange={(e) => setDateOfLeaving(e.target.value)} className={FIELD} />
                </label>
              )}
              {certType === 'leaving' && (
                <label className="block sm:col-span-2">
                  <span className="text-sm text-slate-600">Reason for leaving <span className="text-red-500">*</span></span>
                  <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD}
                    list="leaving-reasons" placeholder="e.g. family relocation" />
                  <datalist id="leaving-reasons">
                    {LEAVING_REASONS.map((x) => <option key={x} value={x} />)}
                  </datalist>
                </label>
              )}
              {needsConduct && (
                <label className="block">
                  <span className="text-sm text-slate-600">Conduct</span>
                  <select value={conduct} onChange={(e) => setConduct(e.target.value)} className={FIELD}>
                    {CONDUCTS.map((c) => <option key={c} value={c}>{c}</option>)}
                  </select>
                </label>
              )}
              {needsPurpose && (
                <label className="block">
                  <span className="text-sm text-slate-600">Purpose</span>
                  <input value={purpose} onChange={(e) => setPurpose(e.target.value)} className={FIELD} placeholder="e.g. bank account opening" />
                </label>
              )}
              <label className="block sm:col-span-2">
                <span className="text-sm text-slate-600">Remarks (optional)</span>
                <input value={remarks} onChange={(e) => setRemarks(e.target.value)} className={FIELD} />
              </label>
            </div>

            {/* What issuing this will actually do. This panel exists because
                every one of these was previously a surprise: the fees still
                owed, the fact that the roll is about to change, and that a
                second copy is a duplicate rather than another original. */}
            {r && (
              <div className="mt-3 space-y-2 text-sm">
                {r.blocked_by_dues ? (
                  <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-amber-900">
                    <div className="font-medium">
                      {fmtPKR(r.balance)} outstanding — a leaving certificate is withheld until fees are cleared.
                    </div>
                    <div className="mt-0.5 text-xs">
                      Take the payment at the fee counter, or have the owner or principal release it below.
                      A released certificate carries the amount and the reason on its face.
                    </div>
                    {maySignOff ? (
                      <div className="mt-2">
                        <label className="flex items-start gap-2">
                          <input type="checkbox" checked={override} onChange={(e) => setOverride(e.target.checked)} className="mt-1" />
                          <span className="text-xs">Release it anyway, on my authority</span>
                        </label>
                        {override && (
                          <input value={overrideReason} onChange={(e) => setOverrideReason(e.target.value)}
                            className={FIELD} placeholder="Why is it being released with fees outstanding? (recorded on the certificate)" />
                        )}
                      </div>
                    ) : (
                      <div className="mt-1 text-xs">Only the owner or principal can release it.</div>
                    )}
                  </div>
                ) : r.dues_gate && (
                  <div className="text-xs text-emerald-700">Fees cleared — nothing outstanding.</div>
                )}

                {certType === 'leaving' && r.left_on == null && (
                  <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-600">
                    Issuing this records {r.student_name || 'the pupil'} as having left on the date above:
                    off the attendance register, out of the class strength, and not billed next month.
                    That is deliberate — a child holding a leaving certificate who is still on the roll
                    is the drift this replaces.
                  </div>
                )}
                {certType === 'leaving' && r.left_on != null && (
                  <div className="text-xs text-slate-500">
                    Already recorded as having left on {fmtDate(r.left_on)} — that date is used and nothing changes.
                  </div>
                )}

                {r.would_be_duplicate && (
                  <div className="rounded border border-slate-300 bg-white px-3 py-2 text-xs text-slate-700">
                    {CERT_LABELS[certType] ?? certType} #{r.original_serial_no} was already issued to this pupil.
                    A second copy is stamped <span className="font-semibold">DUPLICATE COPY</span> and gets its own
                    serial, so the register shows both.
                  </div>
                )}
              </div>
            )}
            {ready.isError && <p className="mt-2 text-sm text-red-600">{(ready.error as Error).message}</p>}

            {issue.isError && <p className="mt-2 text-sm text-red-600">{(issue.error as Error).message}</p>}
            <button onClick={() => issue.mutate()}
              disabled={issue.isPending || ready.isLoading || blocked || missingLeaving || overrideIncomplete}
              className="mt-3 rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {issue.isPending ? 'Issuing…' : override ? 'Release & print' : 'Issue & print'}
            </button>
            {(missingLeaving || overrideIncomplete) && !blocked && (
              <span className="ml-3 text-xs text-slate-500">
                {overrideIncomplete ? 'A reason for the release is required.' : 'The date and reason for leaving are required.'}
              </span>
            )}
          </div>
        )}
      </div>
      )}

      {/* Register */}
      <div className="mt-6">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Certificate register</div>
        <div className="mt-2 overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 w-16">Serial</th>
                <th className="px-3 py-2">Type</th>
                <th className="px-3 py-2">Student</th>
                <th className="px-3 py-2 w-28">Date</th>
                <th className="px-3 py-2">Issued by</th>
                <th className="px-3 py-2 w-32"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {register.data?.length === 0 && <tr><td colSpan={6} className="px-3 py-3 text-slate-500">No certificates issued yet.</td></tr>}
              {register.data?.map((c) => (
                <tr key={c.id} className={c.cancelled_at ? 'bg-slate-50 text-slate-400' : ''}>
                  <td className="px-3 py-2 text-slate-500">
                    <span className={c.cancelled_at ? 'line-through' : ''}>#{c.serial_no}</span>
                  </td>
                  <td className="px-3 py-2 text-slate-800">
                    <span className={c.cancelled_at ? 'text-slate-400 line-through' : ''}>
                      {CERT_LABELS[c.cert_type] ?? c.cert_type}
                    </span>
                    {c.is_duplicate && (
                      <span className="ml-1 rounded bg-slate-200 px-1 text-[10px] font-semibold uppercase text-slate-600">
                        dup of #{c.original_serial_no}
                      </span>
                    )}
                    {!c.dues_cleared && (
                      <span className="ml-1 rounded bg-amber-100 px-1 text-[10px] font-semibold uppercase text-amber-800"
                        title={`Released with ${fmtPKR(c.balance_at_issue)} outstanding`}>
                        released
                      </span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-slate-700">
                    {c.student_name ?? '—'}<span className="text-slate-400">{c.gr_no ? ` · ${c.gr_no}` : ''}</span>
                    {/* A cancelled serial is a fact somebody may have to explain,
                        so the reason is shown rather than the row hidden. */}
                    {c.cancelled_at && (
                      <div className="text-xs text-red-600">
                        Cancelled {fmtDate(c.cancelled_at)}{c.cancel_reason ? ` — ${c.cancel_reason}` : ''}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-slate-500">{fmtDate(c.issued_on)}</td>
                  <td className="px-3 py-2 text-slate-500">{c.issued_by_name ?? '—'}</td>
                  <td className="px-3 py-2 text-right whitespace-nowrap">
                    <button onClick={() => setPrint(toPrint(c))}
                      className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">Reprint</button>
                    {maySignOff && !c.cancelled_at && (
                      <button onClick={() => setCancelling(c)}
                        className="ml-1 rounded border border-red-200 px-2.5 py-1 text-xs font-medium text-red-700 hover:bg-red-50">Cancel</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {print && <CertificatePrint cert={print} onClose={() => setPrint(null)} />}

      {cancelling && (
        <CancelDialog
          cert={cancelling}
          pending={cancel.isPending}
          error={cancel.isError ? (cancel.error as Error).message : null}
          onCancel={() => setCancelling(null)}
          onConfirm={(reason) => cancel.mutate({ id: cancelling.id, reason })}
        />
      )}
    </div>
  )
}

function CancelDialog({
  cert, pending, error, onCancel, onConfirm,
}: {
  cert: CertificateRow; pending: boolean; error: string | null
  onCancel: () => void; onConfirm: (reason: string) => void
}) {
  const [reason, setReason] = useState('')
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">
          Cancel {CERT_LABELS[cert.cert_type] ?? cert.cert_type} #{cert.serial_no}
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          {cert.student_name}{cert.gr_no ? ` · ${cert.gr_no}` : ''}
        </p>
        <p className="mt-2 text-xs text-slate-500">
          The certificate is not deleted — the serial stays in the register, struck through, with this
          reason against it. If the family is holding the printed copy, ask for it back.
        </p>
        <label className="mt-3 block">
          <span className="text-sm text-slate-600">Reason <span className="text-red-500">*</span></span>
          <input autoFocus value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD}
            placeholder="e.g. issued to the wrong child" />
        </label>
        {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
        <div className="mt-4 flex gap-2">
          <button onClick={() => onConfirm(reason.trim())} disabled={pending || !reason.trim()}
            className="flex-1 rounded bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-60">
            {pending ? 'Cancelling…' : 'Cancel certificate'}
          </button>
          <button onClick={onCancel} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Keep it
          </button>
        </div>
      </div>
    </div>
  )
}

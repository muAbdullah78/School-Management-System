import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, issueCertificate, listCertificates, type StudentRow,
} from '@/lib/db'
import { CERT_TYPES, CERT_LABELS } from '@/lib/constants'
import { fmtDate, todayISO } from '@/lib/format'
import { CertificatePrint, type CertificatePrintData } from './CertificatePrint'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'
const CONDUCTS = ['Excellent', 'Very Good', 'Good', 'Satisfactory']

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
  const [print, setPrint] = useState<CertificatePrintData | null>(null)

  const results = useQuery({ queryKey: ['certStudentSearch', term], queryFn: () => searchStudents(term), enabled: term.trim().length >= 2 && !student })
  const register = useQuery({ queryKey: ['certificates'], queryFn: () => listCertificates(50) })

  const issue = useMutation({
    mutationFn: () => {
      const data: Record<string, any> = {}
      if (remarks.trim()) data.remarks = remarks.trim()
      if (certType === 'leaving') { if (dateOfLeaving) data.date_of_leaving = dateOfLeaving; if (reason.trim()) data.reason = reason.trim(); data.conduct = conduct }
      else if (certType === 'character') { data.conduct = conduct }
      else { if (purpose.trim()) data.purpose = purpose.trim() }
      return issueCertificate(certType, student!.id, data)
    },
    onSuccess: async (res) => {
      const list = await listCertificates(50)
      qc.setQueryData(['certificates'], list)
      const row = list.find((c) => c.id === res.id)
      if (row) {
        setPrint({
          certType: row.cert_type, serialNo: row.serial_no, issuedOn: row.issued_on,
          data: row.data, photoPath: row.photo_path,
        })
      }
      setReason(''); setPurpose(''); setRemarks('')
    },
  })

  function reset() { setStudent(null); setTerm('') }

  const needsConduct = certType === 'leaving' || certType === 'character'
  const needsPurpose = certType === 'bonafide' || certType === 'other'

  return (
    <div className="max-w-3xl">
      <h1 className="text-xl font-semibold text-slate-800">Certificates</h1>

      {/* Issue */}
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
                  <span className="text-sm text-slate-600">Date of leaving</span>
                  <input type="date" max={todayISO()} value={dateOfLeaving} onChange={(e) => setDateOfLeaving(e.target.value)} className={FIELD} />
                </label>
              )}
              {certType === 'leaving' && (
                <label className="block">
                  <span className="text-sm text-slate-600">Reason for leaving</span>
                  <input value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD} placeholder="e.g. family relocation" />
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
            {issue.isError && <p className="mt-2 text-sm text-red-600">{(issue.error as Error).message}</p>}
            <button onClick={() => issue.mutate()} disabled={issue.isPending}
              className="mt-3 rounded bg-brand-600 px-5 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {issue.isPending ? 'Issuing…' : 'Issue & print'}
            </button>
          </div>
        )}
      </div>

      {/* Register */}
      <div className="mt-6">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Certificate register</div>
        <div className="mt-2 overflow-hidden rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr><th className="px-3 py-2 w-16">Serial</th><th className="px-3 py-2">Type</th><th className="px-3 py-2">Student</th><th className="px-3 py-2 w-28">Date</th><th className="px-3 py-2 w-24"></th></tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {register.data?.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No certificates issued yet.</td></tr>}
              {register.data?.map((c) => (
                <tr key={c.id}>
                  <td className="px-3 py-2 text-slate-500">#{c.serial_no}</td>
                  <td className="px-3 py-2 text-slate-800">{CERT_LABELS[c.cert_type] ?? c.cert_type}</td>
                  <td className="px-3 py-2 text-slate-700">{c.student_name ?? '—'}<span className="text-slate-400">{c.gr_no ? ` · ${c.gr_no}` : ''}</span></td>
                  <td className="px-3 py-2 text-slate-500">{fmtDate(c.issued_on)}</td>
                  <td className="px-3 py-2 text-right">
                    <button onClick={() => setPrint({ certType: c.cert_type, serialNo: c.serial_no, issuedOn: c.issued_on, data: c.data, photoPath: c.photo_path })}
                      className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">Reprint</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {print && <CertificatePrint cert={print} onClose={() => setPrint(null)} />}
    </div>
  )
}

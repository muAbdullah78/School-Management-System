import { useQuery } from '@tanstack/react-query'
import { useSchoolName } from '@/hooks/useSchoolName'
import { getSchoolSettings } from '@/lib/db'
import { fmtDate } from '@/lib/format'
import { CERT_LABELS } from '@/lib/constants'

export interface CertificatePrintData {
  certType: string
  serialNo: number
  issuedOn: string
  data: Record<string, any>
}

function pronouns(gender: string | undefined) {
  if (gender === 'female') return { subj: 'She', poss: 'Her', rel: 'daughter' }
  if (gender === 'male') return { subj: 'He', poss: 'His', rel: 'son' }
  return { subj: 'They', poss: 'Their', rel: 'child' }
}

function bodyText(certType: string, d: Record<string, any>): string {
  const p = pronouns(d.gender)
  const name = d.student_name ?? 'the student'
  const father = d.father_name ? `, ${p.rel} of ${d.father_name},` : ''
  const cls = d.class_name ? `${d.class_name}${d.section_name ? ` (${d.section_name})` : ''}` : 'this school'
  switch (certType) {
    case 'leaving':
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '—'} `
        + `was a bonafide student of this school, last studying in class ${cls}. `
        + `${p.subj} has left the school${d.date_of_leaving ? ` with effect from ${fmtDate(d.date_of_leaving)}` : ''}`
        + `${d.reason ? ` on account of ${d.reason}` : ''}. `
        + `${p.poss} conduct during ${p.poss.toLowerCase()} stay in the school was ${d.conduct ?? 'satisfactory'}.`
        + (d.remarks ? ` ${d.remarks}` : '')
    case 'character':
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '—'} `
        + `is/was a bonafide student of this school. `
        + `To the best of our knowledge, ${p.poss.toLowerCase()} character and conduct remained ${d.conduct ?? 'good'} `
        + `throughout ${p.poss.toLowerCase()} association with the school.`
        + (d.remarks ? ` ${d.remarks}` : '')
    case 'bonafide':
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '—'} `
        + `is a bonafide student of this school, currently studying in class ${cls}. `
        + `This certificate is issued${d.purpose ? ` for the purpose of ${d.purpose}` : ''} on ${p.poss.toLowerCase()} request.`
        + (d.remarks ? ` ${d.remarks}` : '')
    default:
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '—'} `
        + `is associated with this school${d.class_name ? `, class ${cls}` : ''}.`
        + (d.purpose ? ` Issued for: ${d.purpose}.` : '')
        + (d.remarks ? ` ${d.remarks}` : '')
  }
}

/** A printable certificate rendered from the frozen `data` snapshot. Print with
 *  the browser (Ctrl+P); the print CSS hides all but #certificate. */
export function CertificatePrint({ cert, onClose }: { cert: CertificatePrintData; onClose: () => void }) {
  const schoolName = useSchoolName()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const title = CERT_LABELS[cert.certType] ?? 'Certificate'

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-2xl rounded-lg bg-white p-8 shadow-lg print:max-w-none print:shadow-none" id="certificate">
        <div className="text-center">
          <div className="text-2xl font-bold text-slate-800">{schoolName}</div>
          {settings.data?.address && <div className="text-xs text-slate-500">{settings.data.address}</div>}
          <div className="mt-4 inline-block border-b-2 border-slate-800 pb-1 text-lg font-semibold uppercase tracking-wide text-slate-800">
            {title}
          </div>
        </div>

        <div className="mt-4 flex justify-between text-sm text-slate-600">
          <span>Serial No: <span className="font-semibold text-slate-800">{cert.serialNo}</span></span>
          <span>Date: {fmtDate(cert.issuedOn)}</span>
        </div>

        <p className="mt-6 text-justify text-[15px] leading-8 text-slate-800">{bodyText(cert.certType, cert.data)}</p>

        <p className="mt-6 text-sm text-slate-500">
          We wish {pronouns(cert.data.gender).poss.toLowerCase()} success in all future endeavours.
        </p>

        <div className="mt-16 flex justify-between text-sm text-slate-700">
          <div className="text-center">
            <div className="border-t border-slate-400 px-6 pt-1">Prepared by</div>
          </div>
          <div className="text-center">
            <div className="border-t border-slate-400 px-6 pt-1">{settings.data?.principal_name || 'Principal'}</div>
          </div>
        </div>

        <div className="mt-6 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

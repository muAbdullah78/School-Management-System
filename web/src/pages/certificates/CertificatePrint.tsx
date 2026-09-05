import { useQuery } from '@tanstack/react-query'
import { useSchoolName } from '@/hooks/useSchoolName'
import { getSchoolSettings } from '@/lib/db'
import { fmtDate, fmtPKR } from '@/lib/format'
import { CERT_LABELS } from '@/lib/constants'
import { QrCode } from '@/components/QrCode'
import { Avatar } from '@/components/Avatar'
import { useSchoolLogo } from '@/hooks/useSchoolLogo'
import { signPath } from '@/lib/photos'

export interface CertificatePrintData {
  certType: string
  serialNo: number
  issuedOn: string
  data: Record<string, any>
  /** The pupil's photograph path, for the ID card. Live rather than snapshotted:
   *  a card exists so somebody can recognise the child holding it. */
  photoPath?: string | null
  /** A second copy of a certificate already issued. It has to say so on its
   *  face: two documents that both look original let a family present one at
   *  each of two schools, and leave the school unable to say which is real. */
  isDuplicate?: boolean
  originalSerialNo?: number | null
  /** A cancelled certificate can still be reprinted: somebody may need to see
   *  what was cancelled, but it must never come off the printer looking valid. */
  cancelledAt?: string | null
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
  // `leaving_reason` is the snapshot's key; `reason` is what the old free-form
  // path wrote. Certificates issued before 0061 still have to reprint the same.
  const why = d.leaving_reason ?? d.reason
  switch (certType) {
    case 'leaving':
      // The sentence a Pakistani SLC actually has to carry: "was a bona fide
      // student of this school from ___ to ___, last studying in class ___, and
      // his conduct was ___". Those dates were on the pupil's record all along
      // and were never copied onto the document.
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '-'} `
        + `was a bonafide student of this school`
        + (d.attended_from
            ? ` from ${fmtDate(d.attended_from)} to ${fmtDate(d.attended_to ?? d.date_of_leaving)}`
            : '')
        + `, last studying in class ${cls}. `
        + `${p.subj} has left the school${d.date_of_leaving ? ` with effect from ${fmtDate(d.date_of_leaving)}` : ''}`
        + `${why ? ` on account of ${why}` : ''}. `
        + `${p.poss} conduct during ${p.poss.toLowerCase()} stay in the school was ${d.conduct ?? 'satisfactory'}.`
        // "No dues are outstanding" is the line a receiving school reads, and it
        // must not appear on a certificate the school released WITH fees
        // outstanding. `dues_cleared` is absent on pre-0061 certificates, and
        // absence is not a clearance, so the sentence needs an explicit true.
        + (d.dues_cleared === true ? ` No dues are outstanding against ${p.poss.toLowerCase()} name.` : '')
        + (d.remarks ? ` ${d.remarks}` : '')
    case 'character':
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '-'} `
        + `is/was a bonafide student of this school. `
        + `To the best of our knowledge, ${p.poss.toLowerCase()} character and conduct remained ${d.conduct ?? 'good'} `
        + `throughout ${p.poss.toLowerCase()} association with the school.`
        + (d.remarks ? ` ${d.remarks}` : '')
    case 'bonafide':
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '-'} `
        + `is a bonafide student of this school, currently studying in class ${cls}. `
        + `This certificate is issued${d.purpose ? ` for the purpose of ${d.purpose}` : ''} on ${p.poss.toLowerCase()} request.`
        + (d.remarks ? ` ${d.remarks}` : '')
    default:
      return `This is to certify that ${name}${father} bearing GR No. ${d.gr_no ?? '-'} `
        + `is associated with this school${d.class_name ? `, class ${cls}` : ''}.`
        + (d.purpose ? ` Issued for: ${d.purpose}.` : '')
        + (d.remarks ? ` ${d.remarks}` : '')
  }
}

/** The facts a receiving school or a bank actually checks off the document.
 *  Rendered as a table because a paragraph is what a clerk skim-reads past, and
 *  only for the fields the snapshot holds. A row reading "-" makes a school
 *  look like it does not know its own pupil. */
function FactTable({ certType, d }: { certType: string; d: Record<string, any> }) {
  const rows: [string, string][] = []
  const push = (k: string, v: any) => { if (v != null && v !== '') rows.push([k, String(v)]) }
  push('GR No.', d.gr_no)
  push('Admission No.', d.admission_no)
  push('Date of birth', d.dob ? fmtDate(d.dob) : null)
  push('Date of admission', d.admission_date ? fmtDate(d.admission_date) : null)
  if (certType === 'leaving') {
    push('Date of leaving', d.date_of_leaving ? fmtDate(d.date_of_leaving) : null)
    push('Reason for leaving', d.leaving_reason ?? d.reason)
  }
  push('Class last studied', d.class_name
    ? `${d.class_name}${d.section_name ? ` (${d.section_name})` : ''}` : null)
  push('Board registration no.', d.bise_reg_no)
  push('Conduct', d.conduct)
  if (rows.length === 0) return null
  return (
    <table className="mt-5 w-full border-collapse text-sm">
      <tbody>
        {rows.map(([k, v]) => (
          <tr key={k} className="border-b border-slate-200 last:border-0">
            <td className="w-52 py-1.5 pr-3 align-top text-slate-500">{k}</td>
            <td className="py-1.5 font-medium text-slate-800">{v}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

/** A printable certificate rendered from the frozen `data` snapshot. Print with
 *  the browser (Ctrl+P); the print CSS hides all but #certificate. */
export function CertificatePrint({ cert, onClose }: { cert: CertificatePrintData; onClose: () => void }) {
  const schoolName = useSchoolName()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const logo = useSchoolLogo()
  const title = CERT_LABELS[cert.certType] ?? 'Certificate'

  if (cert.certType === 'id_card') {
    return (
      <IdCardModal
        cert={cert} schoolName={schoolName} address={settings.data?.address ?? null}
        logo={logo} onClose={onClose}
      />
    )
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-2xl rounded-lg bg-white p-8 shadow-lg print:max-w-none print:shadow-none" id="certificate">
        <div className="text-center">
          {/* A leaving certificate is presented to another school, so the
              letterhead does real work. No logo means no line here. The name
              below carries it: never an empty box. */}
          {logo && (
            <img src={logo} alt="" className="mx-auto mb-2 max-h-20 max-w-[12rem] object-contain" />
          )}
          <div className="text-2xl font-bold text-slate-800">{schoolName}</div>
          {settings.data?.address && <div className="text-xs text-slate-500">{settings.data.address}</div>}
          <div className="mt-4 inline-block border-b-2 border-slate-800 pb-1 text-lg font-semibold uppercase tracking-wide text-slate-800">
            {title}
          </div>
        </div>

        {/* A second copy has to say so on its face. Two documents that both look
            original let a family present one at each of two schools, and leave
            the school unable to say afterwards which one was real. */}
        {(cert.isDuplicate ?? cert.data.is_duplicate) === true && (
          <div className="mt-4 border-2 border-slate-800 px-3 py-1.5 text-center text-sm font-bold uppercase tracking-[0.2em] text-slate-800">
            Duplicate copy
            {(cert.originalSerialNo ?? cert.data.original_serial_no) != null && (
              <span className="ml-2 font-normal normal-case tracking-normal text-slate-600">
                (original serial no. {cert.originalSerialNo ?? cert.data.original_serial_no})
              </span>
            )}
          </div>
        )}

        {/* A cancelled certificate can still be reprinted: somebody may need to
            see what was cancelled, but it must never come off the printer
            looking valid. */}
        {cert.cancelledAt && (
          <div className="mt-4 border-2 border-red-600 px-3 py-1.5 text-center text-sm font-bold uppercase tracking-[0.2em] text-red-700">
            Cancelled {fmtDate(cert.cancelledAt)}: not valid
          </div>
        )}

        <div className="mt-4 flex justify-between text-sm text-slate-600">
          <span>Serial No: <span className="font-semibold text-slate-800">{cert.serialNo}</span></span>
          <span>Date: {fmtDate(cert.issuedOn)}</span>
        </div>

        <p className="mt-6 text-justify text-[15px] leading-8 text-slate-800">{bodyText(cert.certType, cert.data)}</p>

        {/* The facts a receiving school checks, laid out rather than buried in the
            paragraph. Only what the snapshot actually holds. An empty row here
            would look like a school that does not know its own pupil. */}
        <FactTable certType={cert.certType} d={cert.data} />

        {/* A leaving certificate released while fees were outstanding says so.
            The alternative is a document that reads as a clearance when it is
            not one, which is worse for the school than for the family. */}
        {cert.data.dues_cleared === false && cert.data.dues_override_reason && (
          <p className="mt-4 rounded border border-slate-300 px-3 py-2 text-xs text-slate-700">
            Issued with {fmtPKR(Number(cert.data.balance_at_issue ?? 0))} outstanding, released on the
            authority of {cert.data.dues_override_by || 'the school'}: {cert.data.dues_override_reason}.
          </p>
        )}

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

/** A printable student ID card with an on-device QR of the GR number. */
function IdCardModal({
  cert, schoolName, address, logo, onClose,
}: {
  cert: CertificatePrintData; schoolName: string; address: string | null
  logo: string | null; onClose: () => void
}) {
  const d = cert.data
  const cls = d.class_name ? `${d.class_name}${d.section_name ? ` · ${d.section_name}` : ''}` : '-'
  const qrText = d.gr_no ? `GR:${d.gr_no}` : `CERT:${cert.serialNo}`
  const photo = useQuery({
    queryKey: ['signedPhoto', cert.photoPath],
    queryFn: () => signPath(cert.photoPath ?? null),
    enabled: !!cert.photoPath,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="print:max-w-none" id="certificate">
        <div className="w-[340px] overflow-hidden rounded-xl border border-slate-300 bg-white shadow-lg print:shadow-none">
          <div className="flex items-center gap-2 bg-brand-700 px-4 py-2 text-white">
            {logo && (
              // A white plate behind the logo: most school logos are dark ink on
              // a transparent background and vanish on the coloured header.
              <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded bg-white p-0.5">
                <img src={logo} alt="" className="max-h-8 max-w-8 object-contain" />
              </span>
            )}
            <div className="min-w-0 flex-1 text-center">
              <div className="truncate text-sm font-semibold leading-tight">{schoolName}</div>
              {address && <div className="truncate text-[10px] text-brand-100/80">{address}</div>}
              <div className="mt-0.5 text-[10px] uppercase tracking-widest text-brand-100">Student ID Card</div>
            </div>
          </div>
          <div className="flex gap-3 p-3">
            {/* A card printed for a pupil with no photograph still has to look
                like a card, so the initials plate fills the same slot. */}
            <Avatar
              name={d.student_name ?? null} url={photo.data ?? null}
              size="lg" square className="!h-24 !w-20 border border-slate-200"
            />
            <div className="min-w-0 flex-1 text-[11px] leading-5 text-slate-700">
              <div className="truncate text-sm font-semibold text-slate-900">{d.student_name ?? '-'}</div>
              {d.father_name && <div className="truncate text-slate-500">c/o {d.father_name}</div>}
              <div className="mt-1 grid grid-cols-[auto,1fr] gap-x-2">
                <span className="text-slate-400">Class</span><span className="truncate">{cls}</span>
                <span className="text-slate-400">Roll</span><span>{d.roll_no ?? '-'}</span>
                <span className="text-slate-400">GR No</span><span>{d.gr_no ?? '-'}</span>
                {d.dob && <><span className="text-slate-400">DOB</span><span>{fmtDate(d.dob)}</span></>}
              </div>
            </div>
          </div>
          <div className="flex items-end justify-between px-3 pb-3">
            <div className="text-[9px] text-slate-400">
              <div>ID #{cert.serialNo}</div>
              <div>Issued {fmtDate(cert.issuedOn)}</div>
              <div className="mt-3 border-t border-slate-300 pt-0.5 text-center text-slate-500">Principal</div>
            </div>
            <QrCode text={qrText} size={72} />
          </div>
        </div>

        <div className="mt-4 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

import { useQuery } from '@tanstack/react-query'
import { useSchoolName } from '@/hooks/useSchoolName'
import { getSchoolSettings, type StaffRow } from '@/lib/db'
import { QrCode } from '@/components/QrCode'
import { Avatar } from '@/components/Avatar'
import { signPath } from '@/lib/photos'

/** A printable staff ID card with an on-device QR. Print-only (staff cards aren't
 *  serial-tracked like student certificates); reuses the #certificate print CSS. */
export function StaffIdCard({ staff, onClose }: { staff: StaffRow; onClose: () => void }) {
  const schoolName = useSchoolName()
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })
  const qrText = staff.employee_no ? `EMP:${staff.employee_no}` : `STAFF:${staff.full_name}`

  // Signed URLs, minted per view. Both queries are keyed on the path so a card
  // reopened for the same person reuses the cached URL instead of re-signing.
  const photo = useQuery({
    queryKey: ['signedPhoto', staff.photo_path],
    queryFn: () => signPath(staff.photo_path),
    enabled: !!staff.photo_path,
  })
  const logo = useQuery({
    queryKey: ['schoolLogo', settings.data?.logo_path],
    queryFn: () => signPath(settings.data?.logo_path ?? null),
    enabled: !!settings.data?.logo_path,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="print:max-w-none" id="certificate">
        <div className="w-[340px] overflow-hidden rounded-xl border border-slate-300 bg-white shadow-lg print:shadow-none">
          <div className="flex items-center gap-2 bg-brand-700 px-4 py-2 text-white">
            {logo.data && (
              // On the coloured header a white plate keeps a dark logo readable;
              // most school logos are dark ink on transparent.
              <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded bg-white p-0.5">
                <img src={logo.data} alt="" className="max-h-8 max-w-8 object-contain" />
              </span>
            )}
            <div className="min-w-0 flex-1 text-center">
              <div className="truncate text-sm font-semibold leading-tight">{schoolName}</div>
              {settings.data?.address && <div className="truncate text-[10px] text-brand-100/80">{settings.data.address}</div>}
              <div className="mt-0.5 text-[10px] uppercase tracking-widest text-brand-100">Staff ID Card</div>
            </div>
          </div>
          <div className="flex gap-3 p-3">
            {/* A card with no photograph still has to look like a card, so the
                initials plate fills the same 20×24 slot the photo would. */}
            <Avatar
              name={staff.full_name} url={photo.data ?? null}
              size="lg" square
              className="!h-24 !w-20 border border-slate-200"
            />
            <div className="min-w-0 flex-1 text-[11px] leading-5 text-slate-700">
              <div className="truncate text-sm font-semibold text-slate-900">{staff.full_name}</div>
              {staff.designation && <div className="truncate text-slate-500">{staff.designation}</div>}
              <div className="mt-1 grid grid-cols-[auto,1fr] gap-x-2">
                <span className="text-slate-400">Emp #</span><span>{staff.employee_no ?? '—'}</span>
                <span className="text-slate-400">Mobile</span><span>{staff.mobile ?? '—'}</span>
              </div>
            </div>
          </div>
          <div className="flex items-end justify-between px-3 pb-3">
            <div className="text-[9px] text-slate-400">
              <div>Staff member</div>
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

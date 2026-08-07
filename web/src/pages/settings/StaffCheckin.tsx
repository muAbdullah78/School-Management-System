import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  generateCheckinCode, listCheckinCodes, getSchoolSettings, updateSchoolSettings,
} from '@/lib/db'
import { QrCode } from '@/components/QrCode'
import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate, todayISO } from '@/lib/format'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

/** Build the deep link a teacher's phone camera opens to check in. */
function checkinUrl(base: string, code: string): string {
  const b = base.replace(/\/+$/, '')
  return `${b}/checkin?c=${code}`
}

export function StaffCheckin() {
  const qc = useQueryClient()
  const schoolName = useSchoolName()
  const codes = useQuery({ queryKey: ['checkinCodes'], queryFn: listCheckinCodes })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const defaultBase = typeof window !== 'undefined' ? window.location.origin : ''
  const [base, setBase] = useState(defaultBase)
  const [label, setLabel] = useState('')
  const [validFrom, setValidFrom] = useState('')
  const [validTo, setValidTo] = useState('')
  const [poster, setPoster] = useState<{ code: string; label: string } | null>(null)

  const gen = useMutation({
    mutationFn: () => generateCheckinCode(label.trim() || `Code ${todayISO()}`, validFrom || null, validTo || null, true),
    onSuccess: (res) => { qc.invalidateQueries({ queryKey: ['checkinCodes'] }); setPoster({ code: res.code, label: label.trim() || 'Check-in' }) },
  })

  const activeCode = codes.data?.find((c) => c.active) ?? null

  return (
    <div className="max-w-2xl space-y-6">
      <div>
        <p className="text-sm text-slate-600">
          Generate a check-in code, print its QR, and put it on the staff-room wall. A teacher scans it with their phone
          camera, signs in, and their attendance is recorded with the server’s date &amp; time. Generating a new code
          deactivates the previous one (so an old printout stops working).
        </p>
      </div>

      {/* Generate */}
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">New check-in code</div>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block"><span className="text-sm text-slate-600">Label</span>
            <input value={label} onChange={(e) => setLabel(e.target.value)} className={FIELD} placeholder="e.g. August 2025" /></label>
          <label className="block"><span className="text-sm text-slate-600">Portal URL (what the QR opens)</span>
            <input value={base} onChange={(e) => setBase(e.target.value)} className={FIELD} placeholder="https://yourschool.pages.dev" /></label>
          <label className="block"><span className="text-sm text-slate-600">Valid from (optional)</span>
            <input type="date" value={validFrom} onChange={(e) => setValidFrom(e.target.value)} className={FIELD} /></label>
          <label className="block"><span className="text-sm text-slate-600">Valid to (optional)</span>
            <input type="date" value={validTo} onChange={(e) => setValidTo(e.target.value)} className={FIELD} /></label>
        </div>
        {gen.isError && <p className="mt-2 text-sm text-red-600">{(gen.error as Error).message}</p>}
        <button onClick={() => gen.mutate()} disabled={gen.isPending}
          className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {gen.isPending ? 'Generating…' : 'Generate & show QR'}
        </button>
      </div>

      {/* Active code + reprint */}
      {activeCode && (
        <div className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="flex items-center justify-between">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Active code</div>
            <button onClick={() => setPoster({ code: activeCode.code, label: activeCode.label ?? 'Check-in' })}
              className="text-sm text-brand-700 hover:underline">Show / print QR</button>
          </div>
          <div className="mt-2 flex items-center gap-4">
            <QrCode text={checkinUrl(base, activeCode.code)} size={96} />
            <div className="text-sm">
              <div className="font-medium text-slate-800">{activeCode.label ?? 'Check-in'}</div>
              <div className="text-slate-500">
                {activeCode.valid_from ? `From ${fmtDate(activeCode.valid_from)}` : 'No start limit'} ·
                {activeCode.valid_to ? ` to ${fmtDate(activeCode.valid_to)}` : ' no expiry'}
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Geofence */}
      <Geofence settings={settings.data} onSaved={() => qc.invalidateQueries({ queryKey: ['schoolSettings'] })} />

      {poster && <Poster schoolName={schoolName} url={checkinUrl(base, poster.code)} label={poster.label} onClose={() => setPoster(null)} />}
    </div>
  )
}

function Geofence({ settings, onSaved }: { settings: any; onSaved: () => void }) {
  const [enabled, setEnabled] = useState(false)
  const [lat, setLat] = useState('')
  const [lng, setLng] = useState('')
  const [radius, setRadius] = useState('200')
  const [geoErr, setGeoErr] = useState<string | null>(null)

  useEffect(() => {
    if (!settings) return
    setEnabled(!!settings.geofence_enabled)
    setLat(settings.geo_lat != null ? String(settings.geo_lat) : '')
    setLng(settings.geo_lng != null ? String(settings.geo_lng) : '')
    setRadius(settings.geo_radius_m != null ? String(settings.geo_radius_m) : '200')
  }, [settings])

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      geofence_enabled: enabled,
      geo_lat: lat.trim() === '' ? null : Number(lat),
      geo_lng: lng.trim() === '' ? null : Number(lng),
      geo_radius_m: Number(radius) || 200,
    }),
    onSuccess: onSaved,
  })

  function useCurrent() {
    setGeoErr(null)
    if (!navigator.geolocation) { setGeoErr('This device has no location support.'); return }
    navigator.geolocation.getCurrentPosition(
      (p) => { setLat(String(p.coords.latitude)); setLng(String(p.coords.longitude)) },
      () => setGeoErr('Could not get location (permission denied?).'),
      { enableHighAccuracy: true, timeout: 8000 },
    )
  }

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Location check (optional)</div>
      <p className="mt-1 text-sm text-slate-600">
        When on, a check-in is only accepted within the set distance of the school — this stops a photographed QR
        being scanned from home. Leave off for a simple honor-system (still logged with time &amp; device).
      </p>
      <label className="mt-3 flex items-center gap-2 text-sm text-slate-700">
        <input type="checkbox" className="h-4 w-4" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
        Require being at school to check in
      </label>
      {enabled && (
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <label className="block"><span className="text-sm text-slate-600">Latitude</span>
            <input value={lat} onChange={(e) => setLat(e.target.value)} className={FIELD} /></label>
          <label className="block"><span className="text-sm text-slate-600">Longitude</span>
            <input value={lng} onChange={(e) => setLng(e.target.value)} className={FIELD} /></label>
          <label className="block"><span className="text-sm text-slate-600">Radius (metres)</span>
            <input type="number" min="20" value={radius} onChange={(e) => setRadius(e.target.value)} className={FIELD} /></label>
          <div className="sm:col-span-3">
            <button type="button" onClick={useCurrent} className="rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-50">
              Use my current location
            </button>
            {geoErr && <span className="ml-2 text-xs text-red-600">{geoErr}</span>}
          </div>
        </div>
      )}
      {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
      <button onClick={() => save.mutate()} disabled={save.isPending}
        className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {save.isPending ? 'Saving…' : 'Save location check'}
      </button>
      {save.isSuccess && <span className="ml-2 text-sm text-emerald-600">Saved.</span>}
    </div>
  )
}

function Poster({ schoolName, url, label, onClose }: { schoolName: string; url: string; label: string; onClose: () => void }) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 print:static print:block print:bg-white print:p-0">
      <div className="w-full max-w-md rounded-lg bg-white p-8 text-center shadow-lg print:max-w-none print:shadow-none" id="report">
        <div className="text-xl font-semibold text-slate-800">{schoolName}</div>
        <div className="mt-1 text-sm uppercase tracking-wide text-slate-500">Staff Check-in — {label}</div>
        <div className="mt-6 flex justify-center"><QrCode text={url} size={280} /></div>
        <ol className="mx-auto mt-6 max-w-xs list-disc pl-5 text-left text-sm text-slate-600">
          <li>Scan this code with your phone camera.</li>
          <li>Sign in with your teacher account.</li>
          <li>Your attendance is recorded automatically.</li>
        </ol>
        <div className="mt-6 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print poster</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

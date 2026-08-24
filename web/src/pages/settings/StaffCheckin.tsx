import { useEffect, useRef, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  generateCheckinCode, listCheckinCodes, getSchoolSettings, updateSchoolSettings,
  getCheckinDisplay, listCheckinAttempts, type SchoolSettings,
} from '@/lib/db'
import { QrCode } from '@/components/QrCode'
import { useSchoolName } from '@/hooks/useSchoolName'
import { fmtDate, todayISO } from '@/lib/format'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

/** Build the deep link a teacher's phone camera opens to check in. */
function checkinUrl(base: string, code: string): string {
  const b = base.replace(/\/+$/, '')
  return `${b}/checkin?c=${encodeURIComponent(code)}`
}

export function StaffCheckin() {
  const qc = useQueryClient()
  const schoolName = useSchoolName()
  const codes = useQuery({ queryKey: ['checkinCodes'], queryFn: listCheckinCodes })
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  const defaultBase = typeof window !== 'undefined' ? window.location.origin : ''
  const [base, setBase] = useState(defaultBase)
  const [label, setLabel] = useState('')
  const [rotating, setRotating] = useState(true)
  const [validFrom, setValidFrom] = useState('')
  const [validTo, setValidTo] = useState('')
  const [poster, setPoster] = useState<{ code: string; label: string } | null>(null)
  const [gate, setGate] = useState(false)

  const gen = useMutation({
    mutationFn: () => generateCheckinCode(
      label.trim() || `Code ${todayISO()}`, validFrom || null, validTo || null, true, rotating),
    onSuccess: (res) => {
      qc.invalidateQueries({ queryKey: ['checkinCodes'] })
      // A rotating code has nothing to print: the QR only exists for 30 seconds
      // at a time, so the school opens the gate screen instead of a poster.
      if (res.rotating) setGate(true)
      else setPoster({ code: res.code, label: label.trim() || 'Check-in' })
    },
  })

  const activeCode = codes.data?.find((c) => c.active) ?? null

  return (
    <div className="max-w-2xl space-y-6">
      <p className="text-sm text-slate-600">
        A teacher records their own attendance by scanning a code, signing in, and the server writes the
        time. A second scan later in the day is their check-out. Nothing else can write the staff register
        except the office — see the register on the Staff page for which rows were scanned and which were typed.
      </p>

      {/* The choice, stated honestly. A school that does not know which mode it
          is in cannot judge its own register. */}
      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">Mode</th><th className="px-3 py-2">What you do</th><th className="px-3 py-2">A photo of it is worth</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            <tr>
              <td className="px-3 py-2 font-medium text-slate-800">Rotating screen</td>
              <td className="px-3 py-2 text-slate-600">Leave a phone, tablet or the office monitor on the gate screen</td>
              <td className="px-3 py-2 font-medium text-emerald-700">under a minute</td>
            </tr>
            <tr>
              <td className="px-3 py-2 font-medium text-slate-800">Printed poster</td>
              <td className="px-3 py-2 text-slate-600">Print the QR once and put it on the wall</td>
              <td className="px-3 py-2 font-medium text-amber-700">for ever</td>
            </tr>
          </tbody>
        </table>
      </div>

      {/* Generate */}
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">New check-in code</div>
        <div className="mt-3 space-y-2">
          <label className="flex items-start gap-2">
            <input type="radio" checked={rotating} onChange={() => setRotating(true)} className="mt-1" />
            <span className="text-sm text-slate-700">
              <span className="font-medium">Rotating code on a screen</span> — recommended.
              The QR changes every 30 seconds, so a photograph stops working almost immediately.
              Needs a device at the gate with the page open.
            </span>
          </label>
          <label className="flex items-start gap-2">
            <input type="radio" checked={!rotating} onChange={() => setRotating(false)} className="mt-1" />
            <span className="text-sm text-slate-700">
              <span className="font-medium">Printed poster</span> — no device needed, but a teacher who
              photographs the poster can check in from home for as long as the code lasts. Set a
              “valid to” date, and turn on the location check below, if you use this.
            </span>
          </label>
        </div>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block"><span className="text-sm text-slate-600">Label</span>
            <input value={label} onChange={(e) => setLabel(e.target.value)} className={FIELD} placeholder="e.g. Main gate" /></label>
          <label className="block"><span className="text-sm text-slate-600">Portal URL (what the QR opens)</span>
            <input value={base} onChange={(e) => setBase(e.target.value)} className={FIELD} placeholder="https://yourschool.pages.dev" /></label>
          <label className="block"><span className="text-sm text-slate-600">Valid from (optional)</span>
            <input type="date" value={validFrom} onChange={(e) => setValidFrom(e.target.value)} className={FIELD} /></label>
          <label className="block"><span className="text-sm text-slate-600">Valid to (optional)</span>
            <input type="date" value={validTo} onChange={(e) => setValidTo(e.target.value)} className={FIELD} /></label>
        </div>
        <p className="mt-2 text-xs text-slate-500">
          Generating a new code deactivates the previous one, so an old printout or a saved link stops working.
        </p>
        {gen.isError && <p className="mt-2 text-sm text-red-600">{(gen.error as Error).message}</p>}
        <button onClick={() => gen.mutate()} disabled={gen.isPending}
          className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {gen.isPending ? 'Generating…' : rotating ? 'Generate & open gate screen' : 'Generate & show QR'}
        </button>
      </div>

      {/* Active code */}
      {activeCode && (
        <div className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="flex items-center justify-between">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">Active code</div>
            {activeCode.rotating ? (
              <button onClick={() => setGate(true)} className="text-sm text-brand-700 hover:underline">Open gate screen</button>
            ) : (
              <button onClick={() => setPoster({ code: activeCode.code, label: activeCode.label ?? 'Check-in' })}
                className="text-sm text-brand-700 hover:underline">Show / print QR</button>
            )}
          </div>
          <div className="mt-2 flex items-center gap-4">
            {activeCode.rotating ? (
              <div className="flex h-24 w-24 shrink-0 items-center justify-center rounded border border-dashed border-slate-300 text-center text-[10px] leading-tight text-slate-400">
                changes every<br />30 seconds
              </div>
            ) : (
              <QrCode text={checkinUrl(base, activeCode.code)} size={96} />
            )}
            <div className="text-sm">
              <div className="font-medium text-slate-800">{activeCode.label ?? 'Check-in'}</div>
              <div className="text-slate-500">
                {activeCode.rotating ? 'Rotating — shown on a screen' : 'Printed poster — static code'}
              </div>
              <div className="text-slate-500">
                {activeCode.valid_from ? `From ${fmtDate(activeCode.valid_from)}` : 'No start limit'}
                {activeCode.valid_to ? ` · to ${fmtDate(activeCode.valid_to)}` : ' · no expiry'}
              </div>
            </div>
          </div>
        </div>
      )}

      <SchoolDay settings={settings.data} onSaved={() => qc.invalidateQueries({ queryKey: ['schoolSettings'] })} />
      <Geofence settings={settings.data} onSaved={() => qc.invalidateQueries({ queryKey: ['schoolSettings'] })} />
      <RefusedAttempts />

      {poster && <Poster schoolName={schoolName} url={checkinUrl(base, poster.code)} label={poster.label} onClose={() => setPoster(null)} />}
      {gate && <GateScreen schoolName={schoolName} base={base} onClose={() => setGate(false)} />}
    </div>
  )
}

/**
 * The screen at the gate. Polls for a fresh token and re-renders the QR.
 *
 * The token comes from the server rather than being computed here: the secret it
 * is derived from never leaves the database, because a rotating code whose seed
 * sits in a browser tab is not a rotating code.
 */
function GateScreen({ schoolName, base, onClose }: { schoolName: string; base: string; onClose: () => void }) {
  const [tick, setTick] = useState(0)
  const [left, setLeft] = useState<number | null>(null)
  const timer = useRef<number | null>(null)

  const disp = useQuery({
    queryKey: ['checkinDisplay', tick],
    queryFn: getCheckinDisplay,
    // A stale token is worse than no token: it refuses a teacher standing at the
    // gate and looks like a fault in the software.
    staleTime: 0, gcTime: 0,
  })

  // Refresh when THIS token expires, not on a fixed interval, so the screen never
  // shows one that has already stopped working.
  useEffect(() => {
    const secs = disp.data?.expires_in
    if (secs == null) return
    setLeft(secs)
    const countdown = window.setInterval(() => setLeft((v) => (v == null ? null : Math.max(0, v - 1))), 1000)
    timer.current = window.setTimeout(() => setTick((t) => t + 1), Math.max(1, secs) * 1000)
    return () => {
      window.clearInterval(countdown)
      if (timer.current) window.clearTimeout(timer.current)
    }
  }, [disp.data?.token, disp.data?.expires_in])

  const d = disp.data
  const url = d?.token ? checkinUrl(base, d.token) : d?.code ? checkinUrl(base, d.code) : null

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900 p-6">
      <div className="w-full max-w-lg text-center">
        <div className="text-2xl font-semibold text-white">{schoolName}</div>
        <div className="mt-1 text-sm uppercase tracking-[0.3em] text-slate-400">Staff check-in</div>

        <div className="mx-auto mt-8 inline-flex items-center justify-center rounded-2xl bg-white p-6">
          {disp.isLoading ? (
            <div className="flex h-[300px] w-[300px] items-center justify-center text-sm text-slate-400">Loading…</div>
          ) : d?.status === 'none' ? (
            <div className="flex h-[300px] w-[300px] items-center justify-center px-6 text-center text-sm text-slate-500">
              No active check-in code. Generate one first.
            </div>
          ) : url ? (
            <QrCode text={url} size={300} />
          ) : null}
        </div>

        {d?.status === 'rotating' && (
          <div className="mt-4 text-sm text-slate-300">
            This code changes in <span className="font-semibold text-white">{left ?? d.period_seconds}s</span>.
            A photograph of it stops working almost immediately.
          </div>
        )}
        {d?.status === 'static' && (
          <div className="mt-4 text-sm text-amber-300">
            This is a static code — a photograph of it keeps working. Switch to a rotating code if you
            want that closed.
          </div>
        )}
        {disp.isError && <p className="mt-4 text-sm text-red-400">{(disp.error as Error).message}</p>}

        <ol className="mx-auto mt-6 max-w-xs list-decimal pl-5 text-left text-sm text-slate-300">
          <li>Scan with your phone camera.</li>
          <li>Sign in with your school account.</li>
          <li>Scan again when you leave.</li>
        </ol>

        <button onClick={onClose} className="mt-8 rounded border border-slate-600 px-4 py-2 text-sm text-slate-200 hover:bg-slate-800">
          Close
        </button>
      </div>
    </div>
  )
}

function SchoolDay({ settings, onSaved }: { settings: SchoolSettings | null | undefined; onSaved: () => void }) {
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [grace, setGrace] = useState('10')

  useEffect(() => {
    if (!settings) return
    setStart((settings.day_starts_at ?? '').slice(0, 5))
    setEnd((settings.day_ends_at ?? '').slice(0, 5))
    setGrace(String(settings.late_grace_minutes ?? 10))
  }, [settings])

  const save = useMutation({
    mutationFn: () => updateSchoolSettings({
      day_starts_at: start.trim() === '' ? null : start,
      day_ends_at: end.trim() === '' ? null : end,
      late_grace_minutes: Number(grace) || 0,
    }),
    onSuccess: onSaved,
  })

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">School day</div>
      <p className="mt-1 text-sm text-slate-600">
        Used to mark a late arrival. <span className="font-medium">Leave the start time empty and nothing is
        ever late</span> — attendance is just present or absent. Setting it applies from now on; it does not
        re-mark days already recorded.
      </p>
      <div className="mt-3 grid gap-3 sm:grid-cols-3">
        <label className="block"><span className="text-sm text-slate-600">Day starts</span>
          <input type="time" value={start} onChange={(e) => setStart(e.target.value)} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Day ends</span>
          <input type="time" value={end} onChange={(e) => setEnd(e.target.value)} className={FIELD} /></label>
        <label className="block"><span className="text-sm text-slate-600">Grace (minutes)</span>
          <input type="number" min="0" max="240" value={grace} onChange={(e) => setGrace(e.target.value)} className={FIELD} /></label>
      </div>
      {save.isError && <p className="mt-2 text-sm text-red-600">{(save.error as Error).message}</p>}
      <button onClick={() => save.mutate()} disabled={save.isPending}
        className="mt-3 rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
        {save.isPending ? 'Saving…' : 'Save school day'}
      </button>
      {save.isSuccess && <span className="ml-2 text-sm text-emerald-600">Saved.</span>}
    </div>
  )
}

function Geofence({ settings, onSaved }: { settings: SchoolSettings | null | undefined; onSaved: () => void }) {
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
      {/* Said plainly, because a school that believes this is proof will trust a
          register it should be checking. The coordinates come from the phone. */}
      <p className="mt-1 text-sm text-slate-600">
        When on, a check-in is only accepted within the set distance of the school. Worth having — but it is
        a <span className="font-medium">deterrent, not proof</span>: the location comes from the teacher’s
        phone, and a phone can be told to report a different one. The rotating code above is the stronger
        protection.
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

/** Somebody trying an old photograph forty times is only visible if the school
 *  can see it. Collapsed by default — this is a place to look when something
 *  seems wrong, not a number to watch all day. */
function RefusedAttempts() {
  const [open, setOpen] = useState(false)
  const attempts = useQuery({ queryKey: ['checkinAttempts'], queryFn: () => listCheckinAttempts(50), enabled: open })

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4">
      <button onClick={() => setOpen((v) => !v)} className="flex w-full items-center justify-between text-left">
        <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">Refused check-ins</span>
        <span className="text-sm text-brand-700">{open ? 'Hide' : 'Show'}</span>
      </button>
      {open && (
        <div className="mt-3">
          {attempts.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
          {attempts.data?.length === 0 && <p className="text-sm text-slate-500">Nothing has been refused.</p>}
          {!!attempts.data?.length && (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead className="text-left text-xs uppercase tracking-wide text-slate-500">
                  <tr><th className="py-1 pr-3">When</th><th className="py-1 pr-3">Who</th><th className="py-1 pr-3">Why</th><th className="py-1">Device</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {attempts.data.map((a) => (
                    <tr key={a.id}>
                      <td className="py-1 pr-3 whitespace-nowrap text-slate-500">
                        {new Date(a.created_at).toLocaleString('en-GB', { timeZone: 'Asia/Karachi' })}
                      </td>
                      <td className="py-1 pr-3 text-slate-700">{a.staff_name ?? '—'}</td>
                      <td className="py-1 pr-3 text-slate-700">{a.reason}</td>
                      <td className="py-1 max-w-[14rem] truncate text-slate-400">{a.device ?? '—'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
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
        <ol className="mx-auto mt-6 max-w-xs list-decimal pl-5 text-left text-sm text-slate-600">
          <li>Scan this code with your phone camera.</li>
          <li>Sign in with your school account.</li>
          <li>Scan again when you leave for the day.</li>
        </ol>
        <p className="mx-auto mt-4 max-w-xs text-left text-xs text-slate-400 print:hidden">
          This is a static code: anybody who photographs this poster can check in from anywhere until it is
          replaced. Use a rotating code on a screen if that matters to you.
        </p>
        <div className="mt-6 flex gap-2 print:hidden">
          <button onClick={() => window.print()} className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">Print poster</button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">Close</button>
        </div>
      </div>
    </div>
  )
}

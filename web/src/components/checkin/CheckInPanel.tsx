import { useState } from 'react'
import { staffCheckIn, type CheckInResult } from '@/lib/db'
import { PinPad } from './PinPad'
import { QrScanner, canScanInApp } from './QrScanner'
import { codeFromScan, coordsProblem, deviceLabel, getCoords } from './checkinKit'
import { buttonClass } from '@/components/ui'

/**
 * The two ways a teacher checks themselves in or out from their own phone:
 * the six digit PIN on big keys, or the QR scanned inside the app.
 *
 * Location is asked for ONLY when the school checks it. Asking a school that
 * does not was a permission prompt with no purpose, and a teacher who says no
 * to a prompt they did not need learns to say no to the one they do. When the
 * school checks it and the phone will not say, the reason is shown here and
 * the server is not called, because every refusal counts towards the ten that
 * lock the account for ten minutes.
 */
export function CheckInPanel({
  intent, mode, geofence, known, onResult,
}: {
  intent: 'in' | 'out'
  /** How the school checks staff in. Null with known=false means the database
   *  is older than bundle 50 and could not say. */
  mode: 'rotating' | 'static' | null
  geofence: boolean
  known: boolean
  onResult: (r: CheckInResult) => void
}) {
  const [tab, setTab] = useState<'pin' | 'scan'>('pin')
  const [pin, setPin] = useState('')
  const [busy, setBusy] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const scanner = canScanInApp()

  async function send(code: string) {
    setErr(null)
    let lat: number | null = null
    let lng: number | null = null
    if (geofence || !known) {
      setBusy('Finding your location…')
      const c = await getCoords(geofence ? 10000 : 4000)
      if (c.ok) { lat = c.lat; lng = c.lng }
      else if (geofence) { setBusy(null); setErr(coordsProblem(c.why)); setPin(''); return }
    }
    setBusy(intent === 'out' ? 'Checking you out…' : 'Checking you in…')
    try {
      const r = await staffCheckIn(code, lat, lng, deviceLabel())
      setPin('')
      onResult(r)
    } catch (e) {
      setErr((e as Error).message)
      setPin('')
    } finally {
      setBusy(null)
    }
  }

  function scanned(raw: string) {
    const code = codeFromScan(raw)
    setTab('pin')
    if (!code) { setErr('That QR is not your school’s check-in code. Scan the one on the gate screen.'); return }
    void send(code)
  }

  const hint = mode === 'rotating'
    ? 'Type the six digit PIN under the QR on the gate screen. It changes every 30 seconds, so type the one showing now.'
    : mode === 'static'
      ? 'Type the six digit PIN printed on the check-in poster.'
      : 'Type the six digit PIN from the gate screen or the check-in poster.'

  return (
    <div>
      <div role="tablist" aria-label="How to check in" className="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1 text-sm font-medium">
        {(['pin', 'scan'] as const).map((t) => (
          <button key={t} type="button" role="tab" aria-selected={tab === t} disabled={!!busy}
            onClick={() => { setTab(t); setErr(null) }}
            className={`rounded-lg px-3 py-2 transition ${tab === t ? 'bg-white text-slate-900 shadow-sm' : 'text-slate-600 hover:text-slate-900'}`}>
            {t === 'pin' ? 'Type the PIN' : 'Scan the QR'}
          </button>
        ))}
      </div>

      {geofence && (
        <p className="mt-3 rounded-xl bg-info-50 px-3 py-2 text-xs text-info-900 ring-1 ring-info-100">
          Your school checks that you are at school, so your phone will ask to share its location. Allow it.
        </p>
      )}

      {err && (
        <p role="alert" className="mt-3 rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-800 ring-1 ring-danger-100">{err}</p>
      )}

      <div className="mt-4">
        {tab === 'pin' ? (
          <>
            <p className="mb-3 text-center text-sm text-slate-600">{hint}</p>
            <PinPad value={pin} onChange={(v) => { setPin(v); if (err) setErr(null) }}
              onComplete={(p) => void send(p)} disabled={!!busy} />
          </>
        ) : scanner ? (
          <QrScanner onCode={scanned} onCancel={() => setTab('pin')} />
        ) : (
          // Safari on an iPhone cannot read a QR inside a web page. Its own
          // Camera app can, and the gate QR is a link that opens this app and
          // checks the teacher in, so that is the honest instruction.
          <div className="rounded-2xl border border-slate-200 bg-slate-50 p-4 text-sm text-slate-700">
            <p className="font-medium text-slate-900">Use your phone’s Camera app</p>
            <ol className="mt-2 list-decimal space-y-1 pl-5">
              <li>Open the Camera and point it at the QR on the gate screen.</li>
              <li>Tap the link that appears. It opens this app and checks you {intent}.</li>
            </ol>
            <p className="mt-2 text-xs text-slate-500">This browser cannot scan inside the app. The PIN works on every phone.</p>
            <button type="button" onClick={() => setTab('pin')} className={buttonClass({ variant: 'soft', size: 'sm', className: 'mt-2' })}>
              Type the PIN instead
            </button>
          </div>
        )}
      </div>

      {busy && <p className="mt-3 text-center text-sm font-medium text-brand-700" aria-live="polite">{busy}</p>}
    </div>
  )
}

import { useEffect, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { staffCheckIn, type CheckInResult } from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { appTitle } from '@/lib/config'

/** Standalone check-in landing (outside the app shell) that a wall-QR deep-links
 *  to (…/checkin?c=CODE). If the teacher isn't signed in, an inline sign-in keeps
 *  them on this page so the code survives. Location is sent best-effort; the
 *  server enforces the geofence only if the school enabled it. */
export function CheckIn() {
  const [params] = useSearchParams()
  const code = params.get('c') ?? ''
  const { session, loading, signIn } = useAuth()
  const schoolName = useSchoolName()

  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [signinErr, setSigninErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [state, setState] = useState<'idle' | 'working' | 'done' | 'error'>('idle')
  const [result, setResult] = useState<CheckInResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [manual, setManual] = useState('')

  async function getCoords(): Promise<{ lat: number | null; lng: number | null }> {
    if (typeof navigator === 'undefined' || !navigator.geolocation) return { lat: null, lng: null }
    return new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lng: p.coords.longitude }),
        () => resolve({ lat: null, lng: null }),
        { enableHighAccuracy: true, timeout: 8000, maximumAge: 60000 },
      )
    })
  }

  async function doCheckIn(override?: string) {
    const use = (override ?? code).trim()
    if (!use) {
      // No code in the link and none typed: fall to the manual box rather than
      // spinning. Common when the camera app strips the query string, or the
      // school reads the poster code out instead of scanning it.
      setState('error'); setError(null); return
    }
    setState('working'); setError(null)
    try {
      const { lat, lng } = await getCoords()
      const device = typeof navigator !== 'undefined' ? navigator.userAgent.slice(0, 120) : null
      const res = await staffCheckIn(use, lat, lng, device)
      setResult(res); setState('done')
    } catch (e) {
      setError((e as Error).message); setState('error')
    }
  }

  // Auto-attempt once signed in, but only when the link carried a code.
  useEffect(() => {
    if (session && state === 'idle' && code) void doCheckIn()
    else if (session && state === 'idle' && !code) setState('error')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session])

  async function onSignIn(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setSigninErr(null)
    const { error } = await signIn(email.trim(), password)
    setBusy(false)
    if (error) setSigninErr(error)
  }

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{appTitle(schoolName)}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Staff check-in</div>
        </div>

        {loading ? (
          <p className="mt-6 text-center text-sm text-slate-500">Loading…</p>
        ) : !session ? (
          <form onSubmit={onSignIn} className="mt-5 space-y-3">
            <p className="text-sm text-slate-600">Sign in to record your attendance.</p>
            <label className="block"><span className="text-sm text-slate-600">Email</span>
              <input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500" /></label>
            <label className="block"><span className="text-sm text-slate-600">Password</span>
              <input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500" /></label>
            {signinErr && <p className="text-sm text-red-600">{signinErr}</p>}
            <button type="submit" disabled={busy}
              className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {busy ? 'Signing in…' : 'Sign in & check in'}
            </button>
          </form>
        ) : state === 'working' || state === 'idle' ? (
          <p className="mt-6 text-center text-sm text-slate-500">Recording your check-in…</p>
        ) : state === 'done' && result ? (
          <div className="mt-6 text-center">
            <div className="text-3xl">{result.status === 'office_marked' ? 'ℹ️' : result.status === 'out' ? '👋' : '✓'}</div>
            <p className={`mt-2 text-sm font-medium ${result.status === 'office_marked' ? 'text-sky-700' : 'text-emerald-700'}`}>
              {result.status === 'out' ? 'Checked out: see you tomorrow.'
                : result.status === 'already' ? 'You were already checked in today.'
                : result.status === 'office_marked'
                  ? 'The office has already recorded today for you.'
                  : result.attendance_status === 'late' ? 'Checked in: marked late.'
                  : 'Checked in: have a great day!'}
            </p>

            {/* A late mark is the school's, not a punishment from the software:
                say by how much so it can be discussed with a real number. */}
            {result.status === 'ok' && result.attendance_status === 'late' && result.late_minutes != null && (
              <p className="mt-1 text-xs text-amber-700">{result.late_minutes} minutes after the start of the day.</p>
            )}

            {/* An office mark outranks a scan, so there is nothing the teacher can
                do here except know about it. Saying what it says is the whole
                value of the message. */}
            {result.status === 'office_marked' && (
              <p className="mt-1 text-xs text-slate-600">
                Recorded as <span className="font-medium">{(result.attendance_status ?? '').replace('_', ' ')}</span>
                {result.reason ? `: ${result.reason}` : ''}. Speak to the office if that is wrong.
              </p>
            )}

            {result.status === 'out' && result.worked_minutes != null && (
              <p className="mt-1 text-xs text-slate-600">
                {Math.floor(result.worked_minutes / 60)}h {String(result.worked_minutes % 60).padStart(2, '0')}m at school today.
              </p>
            )}

            {result.checked_at && (
              <p className="mt-1 text-xs text-slate-500">
                In at {new Date(result.checked_at).toLocaleString('en-PK', { dateStyle: 'medium', timeStyle: 'short' })}
                {result.checked_out_at
                  ? `, out at ${new Date(result.checked_out_at).toLocaleTimeString('en-PK', { timeStyle: 'short' })}`
                  : ''}
              </p>
            )}

            {result.status === 'ok' && (
              <p className="mt-3 text-xs text-slate-400">Scan the code again on your way out.</p>
            )}
          </div>
        ) : (
          <div className="mt-6">
            {error && <p className="text-center text-sm text-red-600">{error}</p>}
            {/* Manual entry: for a camera that would not scan, or a poster code
                read out by the office. A rotating code cannot be typed and the
                server says so, so this is honest about being for the static one. */}
            <p className="mt-2 text-center text-sm text-slate-600">
              {code ? 'Or type today’s code:' : 'Type today’s check-in code:'}
            </p>
            <form className="mt-2 flex items-center justify-center gap-2"
              onSubmit={(e) => { e.preventDefault(); if (manual.trim()) void doCheckIn(manual) }}>
              <input value={manual} onChange={(e) => setManual(e.target.value)}
                placeholder="Code"
                className="w-40 rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500" />
              <button type="submit" disabled={!manual.trim()}
                className="rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                Check in
              </button>
            </form>
            {code && (
              <div className="mt-3 text-center">
                <button onClick={() => doCheckIn()} className="text-xs text-slate-500 hover:underline">Try the scanned code again</button>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

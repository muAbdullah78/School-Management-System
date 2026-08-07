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

  async function doCheckIn() {
    if (!code) { setState('error'); setError('This check-in link is missing its code. Scan the QR again.'); return }
    setState('working'); setError(null)
    try {
      const { lat, lng } = await getCoords()
      const device = typeof navigator !== 'undefined' ? navigator.userAgent.slice(0, 120) : null
      const res = await staffCheckIn(code, lat, lng, device)
      setResult(res); setState('done')
    } catch (e) {
      setError((e as Error).message); setState('error')
    }
  }

  // Auto-attempt once signed in.
  useEffect(() => {
    if (session && state === 'idle') void doCheckIn()
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
        ) : state === 'working' ? (
          <p className="mt-6 text-center text-sm text-slate-500">Recording your check-in…</p>
        ) : state === 'done' && result ? (
          <div className="mt-6 text-center">
            <div className="text-3xl">✓</div>
            <p className="mt-2 text-sm font-medium text-emerald-700">
              {result.status === 'already' ? 'You were already checked in today.' : 'Checked in — have a great day!'}
            </p>
            {result.checked_at && (
              <p className="mt-1 text-xs text-slate-500">
                {new Date(result.checked_at).toLocaleString('en-PK', { dateStyle: 'medium', timeStyle: 'short' })}
              </p>
            )}
          </div>
        ) : (
          <div className="mt-6 text-center">
            <p className="text-sm text-red-600">{error ?? 'Something went wrong.'}</p>
            <button onClick={doCheckIn} className="mt-3 rounded border border-slate-300 px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50">Try again</button>
          </div>
        )}
      </div>
    </div>
  )
}

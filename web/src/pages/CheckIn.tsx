import { useEffect, useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { staffCheckIn, type CheckInResult } from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { appTitle } from '@/lib/config'
import { CheckInPanel } from '@/components/checkin/CheckInPanel'
import {
  STATUS_WORD, deviceLabel, getCoords, hoursWorked, pkTime, resultHeadline,
} from '@/components/checkin/checkinKit'
import { buttonClass } from '@/components/ui'

/**
 * The page the gate QR opens (…/checkin?c=TOKEN), outside the app shell.
 *
 * A teacher who is signed in is checked in at once. One who is not signs in
 * here, and the code survives because the page never leaves. A rotating code
 * changes every 30 seconds, so signing in can take longer than the code lives:
 * when the server says the code has changed, the page says so and offers the
 * PIN keypad, which works with whatever the gate screen shows now.
 */
export function CheckIn() {
  const [params] = useSearchParams()
  const code = params.get('c') ?? ''
  const { session, loading, signIn } = useAuth()
  const schoolName = useSchoolName()

  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [signinErr, setSigninErr] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const [state, setState] = useState<'idle' | 'working' | 'done' | 'manual'>('idle')
  const [result, setResult] = useState<CheckInResult | null>(null)
  const [error, setError] = useState<string | null>(null)
  const tried = useRef(false)

  async function scanIn() {
    setState('working'); setError(null)
    // Best effort: the server decides whether the school needs it, and says so
    // plainly if it does. Four seconds, not ten, because nothing is waiting on
    // it unless the school checks location.
    const c = await getCoords(4000)
    try {
      const res = await staffCheckIn(code, c.ok ? c.lat : null, c.ok ? c.lng : null, deviceLabel())
      setResult(res); setState('done')
    } catch (e) {
      setError((e as Error).message); setState('manual')
    }
  }

  useEffect(() => {
    if (!session || tried.current) return
    tried.current = true
    if (code) void scanIn()
    else setState('manual')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session])

  async function onSignIn(e: React.FormEvent) {
    e.preventDefault(); setBusy(true); setSigninErr(null)
    const { error } = await signIn(email.trim(), password)
    setBusy(false)
    if (error) setSigninErr(error)
  }

  return (
    <div className="flex min-h-full items-start justify-center bg-slate-100 px-4 py-6 sm:items-center">
      <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-card ring-1 ring-slate-200">
        <div className="text-center">
          <div className="text-lg font-semibold text-slate-800">{appTitle(schoolName)}</div>
          <div className="text-xs uppercase tracking-wide text-slate-500">Staff check-in</div>
        </div>

        {loading ? (
          <p className="mt-6 text-center text-sm text-slate-500">Loading…</p>
        ) : !session ? (
          <form onSubmit={onSignIn} className="mt-5 space-y-3">
            <p className="text-sm text-slate-600">Sign in with your school account to record your attendance.</p>
            <label className="block"><span className="text-sm text-slate-600">Email</span>
              <input type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)}
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2.5 text-base focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" /></label>
            <label className="block"><span className="text-sm text-slate-600">Password</span>
              <input type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)}
                className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2.5 text-base focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" /></label>
            {signinErr && <p className="text-sm text-danger-700">{signinErr}</p>}
            <button type="submit" disabled={busy}
              className="w-full rounded-xl bg-brand-600 px-3 py-3 text-sm font-semibold text-white hover:bg-brand-700 disabled:opacity-60">
              {busy ? 'Signing in…' : code ? 'Sign in and check in' : 'Sign in'}
            </button>
          </form>
        ) : state === 'working' || state === 'idle' ? (
          <p className="mt-6 text-center text-sm text-slate-500" aria-live="polite">Recording your check-in…</p>
        ) : state === 'done' && result ? (
          <Done r={result} />
        ) : (
          <div className="mt-5">
            {error && (
              <p role="alert" className="mb-3 rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-800 ring-1 ring-danger-100">
                {error}
                {code && /changed|rotating|not valid/i.test(error) && (
                  <span className="mt-1 block text-xs">Type the PIN showing under the QR now instead.</span>
                )}
              </p>
            )}
            <CheckInPanel intent="in" mode={null} geofence={false} known={false}
              onResult={(r) => { setResult(r); setState('done') }} />
          </div>
        )}

        {session && (
          <div className="mt-5 border-t border-slate-100 pt-3 text-center">
            <Link to="/" className={buttonClass({ variant: 'soft' })}>Open the app</Link>
          </div>
        )}
      </div>
    </div>
  )
}

function Done({ r }: { r: CheckInResult }) {
  const tone = r.status === 'office_marked' || r.status === 'already'
    ? 'text-info-800' : r.attendance_status === 'late' && r.status === 'ok' ? 'text-due-800' : 'text-money-800'
  return (
    <div className="mt-6 text-center" role="status">
      <div className={`mx-auto flex h-14 w-14 items-center justify-center rounded-full text-2xl ${
        r.status === 'office_marked' || r.status === 'already' ? 'bg-info-50 text-info-700' : 'bg-money-50 text-money-700'}`}>
        {r.status === 'office_marked' ? 'i' : r.status === 'out' ? '→' : '✓'}
      </div>
      <p className={`mt-3 text-base font-semibold ${tone}`}>{resultHeadline(r)}</p>

      {r.status === 'ok' && r.attendance_status === 'late' && r.late_minutes != null && (
        <p className="mt-1 text-sm text-due-800">{r.late_minutes} minutes after the start of the day.</p>
      )}
      {r.status === 'office_marked' && (
        <p className="mt-1 text-sm text-slate-600">
          Recorded as <span className="font-medium">{STATUS_WORD[r.attendance_status ?? ''] ?? r.attendance_status}</span>
          {r.reason ? `: ${r.reason}` : ''}. Speak to the office if that is wrong.
        </p>
      )}
      {r.status === 'out' && r.worked_minutes != null && (
        <p className="mt-1 text-sm text-slate-600">{hoursWorked(r.worked_minutes)} at school today.</p>
      )}
      {r.checked_at && (
        <p className="mt-1 text-sm text-slate-500">
          In at {pkTime(r.checked_at)}{r.checked_out_at ? `, out at ${pkTime(r.checked_out_at)}` : ''}
          {r.method === 'pin' ? ' (PIN)' : r.method === 'qr' ? ' (QR)' : ''}
        </p>
      )}
      {r.status === 'ok' && (
        <p className="mt-3 text-xs text-slate-500">Check out on your way home: scan again, or use Check out on your home screen.</p>
      )}
    </div>
  )
}

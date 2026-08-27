import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { supabase } from '@/lib/supabase'
import { appTitle } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'

/**
 * Where the reset link lands.
 *
 * HOW THE LINK ACTUALLY WORKS, because it is not obvious and getting it wrong
 * produces a screen that looks broken for no visible reason. Supabase puts a
 * recovery token in the URL, the client (detectSessionInUrl: true) swaps it for a
 * real session, and updateUser() then changes the password of whoever that
 * session belongs to. So this page is NOT behind ProtectedRoute — it has to be
 * reachable by somebody who is, as far as they know, signed out.
 *
 * THE HALF-SECOND RACE. The exchange is asynchronous. Rendering "this link has
 * expired" the instant the page mounts would show that to everybody, every time,
 * for the moment before the session arrives. So the page waits for either a
 * session or the PASSWORD_RECOVERY event before deciding anything, and shows a
 * neutral "checking the link" until then.
 *
 * WHY IT SIGNS OUT AFTERWARDS. The recovery link is a full sign-in. Somebody who
 * opens it and wanders off is logged in; somebody who forwards the email has
 * forwarded a session. Nothing here can change that — it is how the token works
 * — but once the password is set, ending that session and asking them to sign in
 * with the new one costs a parent ten seconds and leaves the recovery link
 * holding nothing. It also proves to them that the new password works, which is
 * the thing they actually want to know.
 */
export function ResetPassword() {
  const { setPassword, signOut } = useAuth()
  const navigate = useNavigate()
  const schoolName = useSchoolName()
  const [ready, setReady] = useState<'checking' | 'yes' | 'no'>('checking')
  const [pw, setPw] = useState('')
  const [pw2, setPw2] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)

  useEffect(() => {
    if (!supabase) {
      setReady('no')
      return
    }
    let active = true
    // Either the exchange has already happened, or the event is still coming.
    // Both paths are covered because which one fires depends on how fast the
    // network is, and a screen that only handles one of them is a screen that
    // works on a laptop and fails on a phone.
    supabase.auth.getSession().then(({ data }) => {
      if (active && data.session) setReady('yes')
    })
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (!active) return
      if (event === 'PASSWORD_RECOVERY' || s) setReady('yes')
    })
    // If nothing has arrived by then, the link is stale or was opened without
    // its token. Six seconds rather than two: a mid-range Android on a patchy
    // connection is the normal case, not the exception.
    const t = setTimeout(() => {
      if (active) setReady((r) => (r === 'checking' ? 'no' : r))
    }, 6000)
    return () => {
      active = false
      clearTimeout(t)
      sub.subscription.unsubscribe()
    }
  }, [])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    // Checked here rather than after a round trip: being told your two attempts
    // do not match should not cost a network call.
    if (pw !== pw2) {
      setError('The two passwords do not match.')
      return
    }
    if (pw.length < 8) {
      setError('Use at least 8 characters.')
      return
    }
    setBusy(true)
    const { error } = await setPassword(pw)
    setBusy(false)
    if (error) {
      setError(error)
      return
    }
    setDone(true)
    await signOut()
  }

  return (
    <div className="flex h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">{appTitle(schoolName)}</h1>

        {done ? (
          <>
            <p className="mt-3 rounded bg-money-50 px-3 py-2 text-sm text-money-800 ring-1 ring-money-100">
              Your password has been changed. Sign in with the new one.
            </p>
            <button
              onClick={() => navigate('/login', { replace: true })}
              className="mt-5 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Sign in
            </button>
          </>
        ) : ready === 'checking' ? (
          <p className="mt-3 text-sm text-slate-500">Checking the link…</p>
        ) : ready === 'no' ? (
          <>
            <p className="mt-3 rounded bg-due-50 px-3 py-2 text-sm text-due-800 ring-1 ring-due-100">
              This link has expired or has already been used. Reset links last one hour and
              work once.
            </p>
            <Link
              to="/forgot"
              className="mt-5 block w-full rounded bg-brand-600 px-3 py-2 text-center text-sm font-medium text-white hover:bg-brand-700"
            >
              Send a new link
            </Link>
          </>
        ) : (
          <>
            <p className="mt-1 text-sm text-slate-500">Choose a new password.</p>
            <form onSubmit={onSubmit} className="mt-5 space-y-3">
              <label className="block">
                <span className="text-sm text-slate-600">New password</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  autoFocus
                  required
                  value={pw}
                  onChange={(e) => setPw(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </label>
              <label className="block">
                <span className="text-sm text-slate-600">Type it again</span>
                <input
                  type="password"
                  autoComplete="new-password"
                  required
                  value={pw2}
                  onChange={(e) => setPw2(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </label>
              <p className="text-xs text-slate-500">
                At least 8 characters. Do not reuse the password from another site.
              </p>
              {error && <p className="text-sm text-red-600">{error}</p>}
              <button
                type="submit"
                disabled={busy}
                className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
              >
                {busy ? 'Saving…' : 'Set the new password'}
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  )
}

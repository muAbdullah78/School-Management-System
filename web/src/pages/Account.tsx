import { useState, type FormEvent } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { supabase } from '@/lib/supabase'

/**
 * Change my own password.
 *
 * Every role reaches this page: owner, principal, clerk, teacher, parent, so
 * it deliberately lives OUTSIDE both the staff shell and the portal rather than
 * being a tab in Settings. Settings is staff-only, and a parent who wants to
 * change their password after sharing it with a relative is the commonest case
 * of all.
 *
 * IT RE-CHECKS THE CURRENT PASSWORD FIRST, which Supabase's updateUser() does
 * not. Without that, an unattended browser at a school office. The machine at
 * the fee counter, logged in all day: is a machine on which anybody walking
 * past can lock out the account whose session is open. Re-authenticating with
 * signInWithPassword before the change costs one round trip and removes that.
 *
 * On success it signs out. The new password is not proven until it has been used
 * once, and a session left open on the old credential is a session the user
 * believes is protected by the new one.
 */
export function Account() {
  const { session, profile, setPassword, signOut } = useAuth()
  const navigate = useNavigate()
  const [current, setCurrent] = useState('')
  const [pw, setPw] = useState('')
  const [pw2, setPw2] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)

  const email = session?.user?.email ?? ''
  // A parent has no profile row (they are not staff), so this is how the Back
  // button knows where "back" is. Getting it wrong would send a parent to a
  // dashboard they are not allowed to see and bounce them to the portal anyway.
  const home = profile ? '/' : '/portal'

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    if (pw !== pw2) {
      setError('The two new passwords do not match.')
      return
    }
    if (pw.length < 8) {
      setError('Use at least 8 characters.')
      return
    }
    if (pw === current) {
      setError('That is the password you already have.')
      return
    }
    setBusy(true)
    // Re-authenticate. On the wrong password this returns an error and, on
    // Supabase, leaves the existing session intact, so a passer-by guessing
    // gets nowhere and the real user is not signed out of their own session.
    if (supabase && email) {
      const { error: reauth } = await supabase.auth.signInWithPassword({
        email,
        password: current,
      })
      if (reauth) {
        setBusy(false)
        setError('That current password is not right.')
        return
      }
    }
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
    <div className="flex min-h-screen items-start justify-center bg-slate-100 p-4 sm:items-center">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">Change your password</h1>

        {done ? (
          <>
            <p className="mt-3 rounded bg-money-50 px-3 py-2 text-sm text-money-800 ring-1 ring-money-100">
              Done. Sign in again with the new password.
            </p>
            <button
              onClick={() => navigate('/login', { replace: true })}
              className="mt-5 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Sign in
            </button>
          </>
        ) : (
          <>
            <p className="mt-1 truncate text-sm text-slate-500">{email || 'Signed in'}</p>
            <form onSubmit={onSubmit} className="mt-5 space-y-3">
              <label className="block">
                <span className="text-sm text-slate-600">Current password</span>
                <input
                  type="password"
                  autoComplete="current-password"
                  autoFocus
                  required
                  value={current}
                  onChange={(e) => setCurrent(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </label>
              <label className="block">
                <span className="text-sm text-slate-600">New password</span>
                <input
                  type="password"
                  autoComplete="new-password"
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
                At least 8 characters. You will be signed out and asked to sign in with the
                new one.
              </p>
              {error && <p className="text-sm text-red-600">{error}</p>}
              <button
                type="submit"
                disabled={busy}
                className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
              >
                {busy ? 'Saving…' : 'Change password'}
              </button>
              <button
                type="button"
                onClick={() => navigate(home)}
                className="w-full rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50"
              >
                Cancel
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  )
}

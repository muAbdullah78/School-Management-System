import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { appTitle } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'

/**
 * "I have forgotten my password."
 *
 * Until this existed there was NO WAY BACK IN for anybody — a principal, a
 * clerk, or a parent. The only remedy was for the vendor to set a new password
 * by hand and send it over WhatsApp, which is both a support call the vendor
 * cannot scale to fifty schools and a security posture nobody would choose: the
 * vendor knowing a school owner's password.
 *
 * THE SAME SENTENCE FOR EVERY OUTCOME. A real account, a mistyped address, and a
 * stranger checking whether a particular teacher works at a particular school
 * all get "if that address has an account, the link is on its way". Anything
 * more helpful is an account-enumeration oracle, and a school's staff list is
 * exactly the kind of thing somebody would probe for.
 *
 * NO SPINNER-THEN-NOTHING. The confirmation replaces the form rather than
 * flashing a toast, because the next thing the user does is leave for their
 * email, and a message they have to remember is a message they will not act on.
 */
export function ForgotPassword() {
  const { sendReset } = useAuth()
  const schoolName = useSchoolName()
  const [email, setEmail] = useState('')
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await sendReset(email.trim())
    setBusy(false)
    // A failure here is a failure to SEND — offline, or too many attempts. It is
    // never "no such account", which this screen must not disclose.
    if (error) {
      setError(error)
      return
    }
    setSent(true)
  }

  return (
    <div className="flex h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">{appTitle(schoolName)}</h1>

        {sent ? (
          <>
            <p className="mt-3 rounded bg-money-50 px-3 py-2 text-sm text-money-800 ring-1 ring-money-100">
              If that address has an account, a link to set a new password is on its way.
              It is valid for one hour.
            </p>
            <ul className="mt-3 space-y-1.5 text-xs text-slate-500">
              <li>Check the spam or junk folder — reset emails often land there.</li>
              <li>
                Open the link on this device if you can. Opening it on a phone and then
                signing in on the computer works too, but the link itself must be opened
                once.
              </li>
              <li>Nothing arrived? Ask the school office, or try again in a few minutes.</li>
            </ul>
            <Link
              to="/login"
              className="mt-5 block w-full rounded bg-brand-600 px-3 py-2 text-center text-sm font-medium text-white hover:bg-brand-700"
            >
              Back to sign in
            </Link>
          </>
        ) : (
          <>
            <p className="mt-1 text-sm text-slate-500">
              Enter the email address you sign in with and we will send a link to set a new
              password.
            </p>
            <form onSubmit={onSubmit} className="mt-5 space-y-3">
              <label className="block">
                <span className="text-sm text-slate-600">Email</span>
                <input
                  type="email"
                  autoComplete="username"
                  autoFocus
                  required
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                />
              </label>
              {error && <p className="text-sm text-red-600">{error}</p>}
              <button
                type="submit"
                disabled={busy}
                className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
              >
                {busy ? 'Sending…' : 'Send the link'}
              </button>
            </form>
            <p className="mt-4 text-center text-sm text-slate-500">
              <Link to="/login" className="font-medium text-brand-700 hover:underline">
                Back to sign in
              </Link>
            </p>
          </>
        )}
      </div>
    </div>
  )
}

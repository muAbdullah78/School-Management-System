import { useState, type FormEvent } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { appTitle } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'
import {
  AuthError,
  AuthLayout,
  AuthNotice,
  AuthSpinner,
  ReceiptArtefact,
  authButton,
  authButtonLink,
  authField,
  authLabel,
} from '@/components/AuthLayout'

/**
 * "I have forgotten my password."
 *
 * Until this existed there was NO WAY BACK IN for anybody, not a principal, not
 * a clerk, not a parent. The only remedy was for the vendor to set a new
 * password by hand and send it over WhatsApp, which is both a support call the
 * vendor cannot scale to fifty schools and a security posture nobody would
 * choose: the vendor knowing a school owner's password.
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
 *
 * It wears the same frame and the same drawn receipt as /login on purpose.
 * Recovery is a sign-in that went wrong, so it should feel like the same room.
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
    // A failure here is a failure to SEND: offline, or too many attempts. It is
    // never "no such account", which this screen must not disclose.
    if (error) {
      setError(error)
      return
    }
    setSent(true)
  }

  return (
    <AuthLayout
      line="A way back in that does not need a phone call."
      artefact={<ReceiptArtefact />}
    >
      <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">
        {appTitle(schoolName)}
      </h1>

      {sent ? (
        <>
          <div className="mt-5">
            <AuthNotice>
              If that address has an account, a link to set a new password is on its way.
              It is valid for one hour.
            </AuthNotice>
          </div>
          <ul className="mt-4 space-y-2 text-sm text-slate-500">
            <li>Check the spam or junk folder. Reset emails often land there.</li>
            <li>
              Open the link on this device if you can. Opening it on a phone and then
              signing in on the computer works too, but the link itself must be opened
              once.
            </li>
            <li>Nothing arrived? Ask the school office, or try again in a few minutes.</li>
          </ul>
          <Link to="/login" className={`mt-6 ${authButtonLink}`}>
            Back to sign in
          </Link>
        </>
      ) : (
        <>
          <p className="mt-1.5 text-base text-slate-500">
            Enter the email address you sign in with and we will send a link to set a new
            password.
          </p>
          <form onSubmit={onSubmit} className="mt-7 space-y-4">
            <label className="block">
              <span className={authLabel}>Email</span>
              <input
                type="email"
                autoComplete="username"
                autoFocus
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                className={authField}
              />
            </label>
            {error && <AuthError>{error}</AuthError>}
            <button type="submit" disabled={busy} aria-busy={busy} className={authButton}>
              {busy && <AuthSpinner />}
              {busy ? 'Sending' : 'Send the link'}
            </button>
          </form>
          <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
            <Link to="/login" className="font-medium text-brand-700 hover:underline">
              Back to sign in
            </Link>
          </p>
        </>
      )}
    </AuthLayout>
  )
}

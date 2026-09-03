import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import {
  AuthError,
  AuthLayout,
  AuthSpinner,
  authButton,
  authField,
  authLabel,
  AuthBusy,
} from '@/components/AuthLayout'

export function Login() {
  const { signIn } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await signIn(email.trim(), password)
    setBusy(false)
    if (error) {
      setError(error)
      return
    }
    navigate('/', { replace: true })
  }

  return (
    <AuthLayout line="The register, the fee book and the attendance sheet, in one place.">
      {/* The heading is the ACTION. The school's name is in the bar above,
          where it is rendered once for all four screens; repeating it here put
          the same words twice within 30px of each other. */}
      <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">Sign in</h1>
      <p className="mt-1.5 text-base text-slate-500">
        Use the email address your account was set up with.
      </p>
      <form onSubmit={onSubmit} className="mt-7 space-y-4" aria-busy={busy}>
          <AuthBusy label={busy ? 'Signing in' : null} />
        <label className="block">
          <span className={authLabel}>Email</span>
          <input
            type="email"
            autoComplete="username"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={authField}
          />
        </label>
        <label className="block">
          <span className={authLabel}>Password</span>
          <input
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={authField}
          />
        </label>
        {error && <AuthError>{error}</AuthError>}
        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Signing in' : 'Sign in'}
        </button>
      </form>
      <p className="mt-4 text-center text-sm">
        <Link to="/forgot" className="text-slate-500 hover:text-brand-700 hover:underline">
          Forgotten your password?
        </Link>
      </p>
      <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        New school?{' '}
        <Link to="/signup" className="font-medium text-brand-700 hover:underline">
          Start a free 14-day trial
        </Link>
      </p>
    </AuthLayout>
  )
}

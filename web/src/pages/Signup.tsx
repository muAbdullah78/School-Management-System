import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { requireSupabase } from '@/lib/supabase'
import { GateBoard } from '@/components/GateBoard'
import {
  AuthError,
  AuthLayout,
  AuthSpinner,
  authButton,
  authField,
  authHint,
  authLabel,
  AuthBusy,
} from '@/components/AuthLayout'

/**
 * Public signup, the only page in the product reachable without a login.
 *
 * Creates the school and the owner's login in one step (server-side, via the
 * signup-school Edge Function), then signs them straight in. A school owner
 * filling this in on their phone should be inside the app within a minute, not
 * waiting on a confirmation email they may never find.
 *
 * The panel beside it carries the gate board, which echoes whatever is typed
 * into School name. That is the only persuasion on the page and it is the
 * buyer's own input, which is why it can sit on the first field of six.
 */
export function Signup() {
  const navigate = useNavigate()
  const { signIn } = useAuth()
  const [form, setForm] = useState({
    school_name: '', full_name: '', email: '', phone: '', city: '', password: '',
  })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const sb = requireSupabase()
      const { data, error: fnErr } = await sb.functions.invoke('signup-school', { body: form })
      if (fnErr) throw new Error(fnErr.message)
      if (data?.error) throw new Error(data.error)

      // Sign in immediately so they land in the app, not on another form.
      const { error: signInErr } = await signIn(form.email.trim(), form.password)
      if (signInErr) {
        // The account exists; only the automatic sign-in failed. Say so rather
        // than implying the signup itself did not work.
        setError('Your school was created. Please sign in with the email and password you just chose.')
        setBusy(false)
        return
      }
      navigate('/', { replace: true })
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <AuthLayout
      line="Fourteen days free, then from Rs 950 a month."
      artefact={<GateBoard name={form.school_name} />}
    >
      <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">
        Start your free trial
      </h1>
      <p className="mt-1.5 text-base text-slate-500">
        14 days free. No card needed: pay by bank transfer only if you decide to continue.
      </p>

      <form onSubmit={onSubmit} className="mt-7 space-y-4" aria-busy={busy}>
          <AuthBusy label={busy ? 'Creating your school' : null} />
        <label className="block">
          <span className={authLabel}>School name</span>
          <input
            autoComplete="organization"
            required
            value={form.school_name}
            onChange={set('school_name')}
            className={authField}
          />
        </label>
          <p id="pw-hint" className={authHint}>At least 8 characters.</p>
        <label className="block">
          <span className={authLabel}>Your name</span>
          <input
            autoComplete="name"
            required
            value={form.full_name}
            onChange={set('full_name')}
            className={authField}
          />
        </label>
        <div className="grid grid-cols-2 gap-3">
          <label className="block">
            <span className={authLabel}>City</span>
            <input
              autoComplete="address-level2"
              value={form.city}
              onChange={set('city')}
              className={authField}
            />
          </label>
          <label className="block">
            <span className={authLabel}>Mobile / WhatsApp</span>
            <input
              type="tel"
              autoComplete="tel"
              value={form.phone}
              onChange={set('phone')}
              className={authField}
            />
          </label>
        </div>
        <label className="block">
          <span className={authLabel}>Email</span>
          <input
            type="email"
            autoComplete="username"
            required
            value={form.email}
            onChange={set('email')}
            className={authField}
          />
        </label>
        <label className="block">
          <span className={authLabel}>Choose a password</span>
          <input
            type="password" autoComplete="new-password" required minLength={8}
            value={form.password} onChange={set('password')} className={authField} aria-describedby="pw-hint"
          />
          
        </label>

        {error && <AuthError>{error}</AuthError>}

        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Creating your school' : 'Create my school'}
        </button>
      </form>

      <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        Already have an account?{' '}
        <Link to="/login" className="font-medium text-brand-700 hover:underline">Sign in</Link>
      </p>
    </AuthLayout>
  )
}

import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { requireSupabase } from '@/lib/supabase'

/**
 * Public signup — the only page in the product reachable without a login.
 *
 * Creates the school and the owner's login in one step (server-side, via the
 * signup-school Edge Function), then signs them straight in. A school owner
 * filling this in on their phone should be inside the app within a minute, not
 * waiting on a confirmation email they may never find.
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
        setError('Your school was created — please sign in with the email and password you just chose.')
        setBusy(false)
        return
      }
      navigate('/', { replace: true })
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  const field = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">Start your free trial</h1>
        <p className="mt-1 text-sm text-slate-500">
          14 days free. No card needed — pay by bank transfer only if you decide to continue.
        </p>

        <form onSubmit={onSubmit} className="mt-5 space-y-3">
          <label className="block">
            <span className="text-sm text-slate-600">School name</span>
            <input required value={form.school_name} onChange={set('school_name')} className={field} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Your name</span>
            <input required value={form.full_name} onChange={set('full_name')} className={field} />
          </label>
          <div className="grid grid-cols-2 gap-3">
            <label className="block">
              <span className="text-sm text-slate-600">City</span>
              <input value={form.city} onChange={set('city')} className={field} />
            </label>
            <label className="block">
              <span className="text-sm text-slate-600">Mobile / WhatsApp</span>
              <input value={form.phone} onChange={set('phone')} className={field} />
            </label>
          </div>
          <label className="block">
            <span className="text-sm text-slate-600">Email</span>
            <input type="email" autoComplete="username" required value={form.email} onChange={set('email')} className={field} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Choose a password</span>
            <input
              type="password" autoComplete="new-password" required minLength={8}
              value={form.password} onChange={set('password')} className={field}
            />
            <span className="mt-1 block text-xs text-slate-500">At least 8 characters.</span>
          </label>

          {error && <p className="text-sm text-red-600">{error}</p>}

          <button
            type="submit" disabled={busy}
            className="w-full rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
          >
            {busy ? 'Creating your school…' : 'Create my school'}
          </button>
        </form>

        <p className="mt-4 text-center text-sm text-slate-500">
          Already have an account?{' '}
          <Link to="/login" className="font-medium text-brand-700 hover:underline">Sign in</Link>
        </p>
      </div>
    </div>
  )
}

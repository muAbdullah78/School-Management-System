import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { requireSupabase } from '@/lib/supabase'
import { listRegions } from '@/lib/plans'
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
import { SIGNUP_DOOR } from '@/auth/doors'

/**
 * Step one of signup: who you are and where you are. Nothing about money.
 *
 * WHAT THIS SCREEN USED TO BE, AND WHY IT WAS TOO MUCH. It asked for six
 * details AND made a commercial decision: which of three plans, and which of
 * three payment terms, with nine prices and two savings figures on screen. A
 * school owner who has not yet typed their own name was being asked to choose a
 * band and a billing cycle, and the panel that asked it was the tallest thing
 * on the page. Six facts somebody already knows and one decision they have to
 * make do not belong on one screen: the facts are typed without thinking and
 * the decision is not, and putting them together makes the whole form feel like
 * the decision.
 *
 * So the plan moved to its own screen, where it can be shown properly with the
 * invoice it produces. See pages/ChoosePlan.tsx.
 *
 * THE ACCOUNT IS CREATED HERE, at the end of step one, and that is the answer
 * to what happens when somebody abandons step two. The alternative is holding
 * this form in the browser and creating nothing until the plan is chosen, and
 * then a closed tab loses a real customer who has already given us everything.
 * Storing the half-filled form instead would mean a public, unauthenticated
 * endpoint holding a stranger's email and telephone number: a spam target and a
 * pile of personal data nobody agreed to. There is no partial state here
 * because there is no partial state. A school that stops after this screen is a
 * real customer on a real fourteen-day trial, on the first plan on sale, who
 * can change it from Settings whenever they like.
 *
 * REGION IS NEW AND IT IS ABOVE CITY, not beside it. The product is sold by
 * province, and city alone does not answer which one: "Model Town" is in three
 * of them. The list comes from the database through fn_signup_regions, so the
 * form and the check constraint on schools.region cannot disagree about a
 * spelling and refuse a signup at its last step.
 */
export function Signup() {
  const navigate = useNavigate()
  const { signIn } = useAuth()
  const [form, setForm] = useState({
    school_name: '', full_name: '', email: '', phone: '',
    region: '', city: '', password: '',
  })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  /* THE REGION LIST, AND WHAT HAPPENS WHEN IT IS NOT THERE.
   *
   * The first version of this screen marked the field `required` while its
   * options came from a network call, and the comment above it claimed the
   * field stayed optional without a list. The code said otherwise. When
   * fn_signup_regions could not be reached the select held one option, the
   * empty placeholder, and `required` refuses that: the browser answers "Please
   * select an item in the list" and there is no item to select. A DEAD SIGNUP
   * FORM, on the one screen in the product with no login behind it, reported by
   * the vendor on his own signup.
   *
   * It was not a hypothetical failure either. fn_signup_regions arrives with
   * bundle 37, and between deploying this app and pasting that bundle every
   * school saw an empty dropdown it could not get past.
   *
   * SO THE RULE IS: required when there is something to choose, and not
   * rendered at all when there is not. Nothing about a school's own signup may
   * depend on a read succeeding.
   *
   * AND IT IS HIDDEN RATHER THAN SHOWN EMPTY, which is the part worth arguing.
   * If fn_signup_regions is missing then fn_signup_school_on_plan_in_region is
   * missing too, because they arrive in the same bundle, and the Edge Function
   * falls back to the name that has no region parameter. So a region chosen in
   * that state is discarded on the way past. A field whose answer is thrown
   * away is worse than a field that is not asked.
   *
   * NO HARDCODED FALLBACK LIST, for the same reason. It would offer seven
   * provinces, let somebody pick one, and drop it. The vendor is told instead,
   * by verify.sql's 0132 row, which is where a missing bundle belongs.
   */
  const regions = useQuery({ queryKey: ['signupRegions'], queryFn: listRegions })
  const regionOptions = regions.data ?? []
  const askRegion = regions.isLoading || regionOptions.length > 0

  const set = (k: keyof typeof form) =>
    (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
      setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const sb = requireSupabase()
      // NO PLAN AND NO TERM. fn_signup_school_on_plan defaults to the first
      // plan on sale for one month, and the next screen writes what they
      // actually choose. Sending a plan from here would mean two screens that
      // both set it, and one of them would be wrong.
      const { data, error: fnErr } = await sb.functions.invoke('signup-school', {
        body: form,
      })
      if (fnErr) throw new Error(fnErr.message)
      if (data?.error) throw new Error(data.error)

      const { error: signInErr } = await signIn(form.email.trim(), form.password)
      if (signInErr) {
        setError('Your school was created. Please sign in with the email and password you just chose.')
        setBusy(false)
        return
      }
      navigate('/plan', { replace: true })
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  return (
    <AuthLayout
      door={{ ...SIGNUP_DOOR, line: 'Fourteen days free, then from Rs 2,000 a month.' }}
      schoolName={form.school_name}
    >
      <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">
        Start your free trial
      </h1>
      <p className="mt-1.5 text-base text-slate-500">
        14 days free. No card needed: pay by bank transfer only if you decide to continue.
      </p>
      {/* WHERE THEY ARE IN THE FLOW, said before the first field rather than
          after the last one. A button reading "Next step" with no indication of
          how many steps there are reads as an open-ended form. */}
      <p className="mt-4 text-sm font-medium text-slate-500">
        Step 1 of 2 <span className="text-slate-300">&middot;</span> Your details
      </p>

      <form onSubmit={onSubmit} className="mt-4 space-y-4" aria-busy={busy}>
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
        {/* REGION FIRST AND ON ITS OWN ROW. It is a closed list of seven and it
            qualifies the city under it, so it reads as the question it is:
            which province, then which town in it. Paired with the city in a
            two-column row it would be a 170px dropdown holding "Islamabad
            Capital Territory".

            Rendered only when there is a list to render. See the note beside
            the query: required with no options is a form nobody can submit. */}
        {askRegion && (
          <label className="block">
            <span className={authLabel}>Region</span>
            <select
              required={regionOptions.length > 0}
              disabled={regions.isLoading}
              value={form.region}
              onChange={set('region')}
              className={authField}
            >
              <option value="">
                {regions.isLoading ? 'Loading…' : 'Select a province or territory…'}
              </option>
              {regionOptions.map((r) => (
                <option key={r} value={r}>{r}</option>
              ))}
            </select>
          </label>
        )}
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
        {/* The hint is a SIBLING of the label, not a child of it. Text inside
            <label> joins the input's accessible name, so a screen reader would
            read the field as "Choose a password At least 8 characters"; as a
            described-by it is announced after the name, which is what a hint
            is. */}
        <div>
          <label className="block">
            <span className={authLabel}>Choose a password</span>
            <input
              type="password" autoComplete="new-password" required minLength={8}
              value={form.password} onChange={set('password')} className={authField} aria-describedby="pw-hint"
            />
          </label>
          <p id="pw-hint" className={authHint}>At least 8 characters.</p>
        </div>

        {error && <AuthError>{error}</AuthError>}

        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Creating your school' : 'Next step'}
        </button>

        {/* THE LAST WORD BEFORE THE BUTTON IS WHAT IS NOT HAPPENING. */}
        <p className="text-center text-xs text-slate-500">
          Nothing is charged and no card is needed. The next screen is which plan
          you want, and you can change it at any time.
        </p>
      </form>

      <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        Already have an account?{' '}
        <Link to="/login" className="font-medium text-brand-700 hover:underline">Sign in</Link>
      </p>
    </AuthLayout>
  )
}

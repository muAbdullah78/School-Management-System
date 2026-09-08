import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { requireSupabase } from '@/lib/supabase'
import { listSignupPlans, TERM_LABEL, type SignupPlan } from '@/lib/plans'
import { formatPkr } from '@/lib/licence'
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
 * Public signup, the only page in the product reachable without a login.
 *
 * Creates the school and the owner's login in one step (server-side, via the
 * signup-school Edge Function), then signs them straight in. A school owner
 * filling this in on their phone should be inside the app within a minute, not
 * waiting on a confirmation email they may never find.
 *
 * The mockup beside it carries whatever is typed into School name, so the
 * owner sees their own school inside the product before they have finished the
 * form. That is the only persuasion on the page and it is the buyer's own
 * input, which is why it can sit on the first field of six. Below 1024px the
 * mockup is not rendered, so on a phone the form is the whole page.
 *
 * IT NOW ASKS WHICH PLAN AND HOW OFTEN, and it did not. fn_signup_school
 * hardcoded `starter` and left `term_months` at the column default of 12, so
 * every school in the console was on Starter paying annually whatever had
 * actually been agreed, and Settings quoted them Rs 20,000 they had never
 * chosen. Nobody was asked, on the one screen where the question belongs.
 *
 * MONTHLY IS THE PRESELECTED TERM, not yearly, and that is a deliberate
 * reversal of what the code did by accident. Preselecting the largest charge
 * on a buying screen is a dark pattern, and it is the exact complaint that
 * started this: an annual figure nobody picked. The yearly saving is shown in
 * rupees beside the yearly button so a school can choose it for its own
 * reasons. It also converts better: the first invoice after the trial is
 * Rs 2,000 rather than Rs 20,000.
 *
 * THE PRICES COME FROM THE DATABASE, through fn_signup_plans, and the reason
 * is in web/src/lib/plans.ts: fn__plan_price is a rule and not a lookup, and a
 * browser reimplementation of it would quote a figure the first invoice
 * contradicts the moment any of the nine rates moves.
 */
export function Signup() {
  const navigate = useNavigate()
  const { signIn } = useAuth()
  const [form, setForm] = useState({
    school_name: '', full_name: '', email: '', phone: '', city: '', password: '',
  })
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const plans = useQuery({ queryKey: ['signupPlans'], queryFn: listSignupPlans })
  const [picked, setPicked] = useState<string | null>(null)
  const [term, setTerm] = useState(1)

  // DERIVED, NOT SET BY AN EFFECT. The default is the first plan on sale, which
  // is the smallest and cheapest; `picked` only holds a deliberate choice. An
  // effect that set it after the first render left the summary line under the
  // button reading the no-plan fallback on the first paint, in the browser and
  // in the rendering harness, which is where it was noticed. Not a hardcoded
  // 'starter' either: hardcoding the plan is the whole defect this change is
  // about, and plans.sort_order already says which one a school starts on.
  const chosen = plans.data?.find((p) => p.code === picked) ?? plans.data?.[0] ?? null
  const chosenTerm = chosen?.terms.find((x) => x.months === term) ?? null

  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      const sb = requireSupabase()
      // The plan and the term are sent alongside the form fields. Both are
      // validated again in fn_signup_school, because this Edge Function is the
      // one public unauthenticated entry point in the product and a body
      // posted straight at it must not be able to put a school on a retired
      // plan, on a plan priced by arrangement, or on a 47-month term.
      const { data, error: fnErr } = await sb.functions.invoke('signup-school', {
        body: { ...form, plan_code: chosen?.code ?? null, term_months: term },
      })
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
      door={{ ...SIGNUP_DOOR, line: 'Fourteen days free, then from Rs 2,000 a month.' }}
      schoolName={form.school_name}
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
        {/* The hint is a SIBLING of the label, not a child of it. Text inside
            <label> joins the input's accessible name, so a screen reader would
            read the field as "Choose a password At least 8 characters"; as a
            described-by it is announced after the name, which is what a hint
            is. Both are wrapped so the form's space-y-4 applies to the pair
            rather than pushing the hint away from its field. */}
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

        <PlanChooser
          plans={plans.data ?? []}
          loading={plans.isLoading}
          failed={!!plans.error}
          planCode={chosen?.code ?? null}
          setPlanCode={setPicked}
          term={term}
          setTerm={setTerm}
        />

        {error && <AuthError>{error}</AuthError>}

        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Creating your school' : 'Create my school'}
        </button>

        {/* THE LAST WORD BEFORE THE BUTTON IS WHAT IS NOT HAPPENING. A school
            that has just picked a plan and a term needs to know, in the same
            glance, that pressing this does not charge anything. */}
        <p className="text-center text-xs text-slate-500">
          {chosen && chosenTerm
            ? `14 days free. After that ${formatPkr(chosenTerm.amount)} ${
                term === 1 ? 'a month' : term === 3 ? 'every three months' : 'a year'
              }, and you can change the plan or the term any time from Settings.`
            : '14 days free. No card needed.'}
        </p>
      </form>

      <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        Already have an account?{' '}
        <Link to="/login" className="font-medium text-brand-700 hover:underline">Sign in</Link>
      </p>
    </AuthLayout>
  )
}

/**
 * Which plan, and how often.
 *
 * WHY IT IS A PANEL AT THE FOOT OF THE FORM rather than two more fields in the
 * middle of it. The six fields above are facts a school owner already knows and
 * types without thinking. This is the one decision on the page, and it belongs
 * where they are about to press the button rather than between their own name
 * and their email address.
 *
 * WHY THE BANDS ARE STATED ON EVERY CARD. The question a school owner can
 * answer is "how many children do we have", not "which of your three tiers are
 * we". `plans.name` already carries the band ("Starter (up to 150 students)")
 * because the operator console and the invoices show the same string, so the
 * card can say it without this component inventing a second copy of the
 * numbers.
 *
 * WHAT IT DOES WHEN THE PRICE LIST WILL NOT LOAD. It says so and gets out of
 * the way, and the form still submits: plan_code null and term_months 1 reach
 * fn_signup_school, which falls back to the first plan on sale. A signup form
 * that refuses to submit because a price could not be fetched loses a customer
 * over a network blip.
 */
function PlanChooser({
  plans, loading, failed, planCode, setPlanCode, term, setTerm,
}: {
  plans: SignupPlan[]
  loading: boolean
  failed: boolean
  planCode: string | null
  setPlanCode: (c: string) => void
  term: number
  setTerm: (m: number) => void
}) {
  if (loading) {
    return (
      <div className="rounded-lg border border-slate-200 bg-slate-50/70 p-3">
        <p className="text-xs text-slate-500">Loading the plans…</p>
      </div>
    )
  }
  if (failed || plans.length === 0) {
    return (
      <div className="rounded-lg border border-slate-200 bg-slate-50/70 p-3">
        <p className="text-xs text-slate-600">
          We could not load the plans just now. Carry on and create your school:
          it starts on a 14-day free trial either way, and you can pick the plan
          and how often you pay from Settings afterwards.
        </p>
      </div>
    )
  }

  const chosen = plans.find((p) => p.code === planCode) ?? plans[0]

  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50/70 p-3">
      <fieldset>
        <legend className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Which plan?
        </legend>
        {/* FULL-WIDTH ROWS AND NOT A THREE-ACROSS GRID. Three cards in this
            column are about 150px each, which wrapped "up to 150 children"
            and "from Rs 2,000/month" onto two lines apiece and made the panel
            taller than the rows version anyway. Seen in the rendering
            harness, which is what it is for. Rows also read the same on a
            phone, where a three-column grid collapses to this shape. */}
        <div className="mt-2 space-y-1.5">
          {plans.map((p) => {
            const on = p.code === chosen.code
            const monthly = p.terms.find((x) => x.months === 1)
            return (
              <label
                key={p.code}
                className={`flex cursor-pointer items-baseline justify-between gap-3 rounded border px-3 py-2 ${
                  on ? 'border-brand-600 bg-white ring-1 ring-brand-600'
                     : 'border-slate-300 bg-white hover:bg-slate-50'}`}
              >
                <input
                  type="radio"
                  name="plan"
                  value={p.code}
                  checked={on}
                  onChange={() => setPlanCode(p.code)}
                  className="sr-only"
                />
                <span className="min-w-0">
                  <span className="block text-sm font-medium text-slate-800">
                    {/* The band is in the name; the leading word is the plan. */}
                    {p.name.replace(/\s*\(.*$/, '')}
                  </span>
                  <span className="block text-xs text-slate-500">
                    {p.student_limit === null
                      ? 'any number of children'
                      : `up to ${p.student_limit.toLocaleString()} children`}
                  </span>
                </span>
                {monthly && (
                  <span className="shrink-0 text-xs tabular-nums text-slate-700">
                    from {formatPkr(monthly.amount)}/month
                  </span>
                )}
              </label>
            )
          })}
        </div>
      </fieldset>

      <fieldset className="mt-3">
        <legend className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          How often will you pay?
        </legend>
        <div className="mt-2 flex flex-wrap gap-1.5">
          {chosen.terms.map((x) => {
            const on = x.months === term
            return (
              <label
                key={x.months}
                className={`cursor-pointer rounded border px-2.5 py-1.5 text-left ${
                  on ? 'border-brand-600 bg-brand-600 text-white'
                     : 'border-slate-300 bg-white text-slate-700 hover:bg-slate-50'}`}
              >
                <input
                  type="radio"
                  name="term"
                  value={x.months}
                  checked={on}
                  onChange={() => setTerm(x.months)}
                  className="sr-only"
                />
                <span className="block text-xs font-medium">
                  {TERM_LABEL[x.months] ?? `${x.months} months`}
                </span>
                <span className={`block text-xs tabular-nums ${
                  on ? 'text-brand-100' : 'text-slate-500'}`}>
                  {formatPkr(x.amount)}
                </span>
                {/* IN RUPEES, NOT AS A PERCENTAGE, and read from the database
                    rather than typed here. A saving stated as "16.7 percent"
                    is homework; one stated as "Rs 4,000" is a number a school
                    can weigh against something it wants. And the figure moves
                    when the price list moves. */}
                {x.saving > 0 && (
                  <span className={`block text-xs ${
                    on ? 'text-brand-100' : 'text-money-700'}`}>
                    save {formatPkr(x.saving)}
                  </span>
                )}
              </label>
            )
          })}
        </div>
      </fieldset>

      {/* The plan a school cannot pick for itself, said plainly rather than
          shown as a fourth card that refuses. It has no price and no student
          limit, so self-serving onto it would be unlimited pupils for nothing:
          fn_signup_school refuses it and fn_signup_plans does not offer it. */}
      <p className="mt-2.5 text-xs text-slate-500">
        More than {(plans[plans.length - 1].student_limit ?? 600).toLocaleString()}{' '}
        children? Start on{' '}
        {plans[plans.length - 1].name.replace(/\s*\(.*$/, '')} and tell us: we
        price bigger schools with you and move you across, and nothing you enter
        is lost when we do.
      </p>
    </div>
  )
}

import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { requireSupabase } from '@/lib/supabase'
import { listRegions, listSignupPlans, planForStudents, TERM_LABEL, type SignupPlan } from '@/lib/plans'
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

/** The most pupils a school can sign up with; the database refuses more. */
const MOST_PUPILS = 100_000

type Term = 1 | 3 | 12

/** A whole number of pupils from what was typed, or null. */
export function pupilsFrom(typed: string): number | null {
  const t = typed.trim()
  if (!/^\d+$/.test(t)) return null
  const n = Number(t)
  return n >= 1 && n <= MOST_PUPILS ? n : null
}

/**
 * Signup: who you are, where you are, and how many pupils you have. The plan
 * and its price follow from that number, on this screen, before anything is
 * created.
 *
 * WHY THE PRICE IS BACK ON THIS SCREEN. The previous version took the plan off
 * signup altogether and asked for it on a second screen, after the account
 * existed. That kept the form short, and it meant a school agreed to nothing it
 * could see: it created an account and only then found out what it would cost.
 * Since 0155 a school does not choose a plan at all. It says how many pupils
 * are on its roll and the plan follows (up to 280 Starter, up to 1,000 Growth,
 * more than that Enterprise), so the commercial part of signup is one number
 * the owner already knows, and the answer to it can be shown as they type.
 *
 * EVERY FIGURE ON IT COMES FROM THE DATABASE. fn_signup_plans gives the three
 * plans, their ranges and the three terms of each with what each saves, priced
 * by the same function that prices the first invoice. planForStudents mirrors
 * the database's rule only to choose which plan to show; the database applies
 * it again when the school is created, from the number this form sends.
 *
 * ENTERPRISE HAS NO FIGURE, and says so instead of hiding it: we agree the
 * price with each school during its trial, and an Enterprise school with no
 * price locks the day its trial ends, because there is nothing to invoice it
 * for and so no grace to give. A school that large is owed that sentence
 * before it signs up, not after its trial has run out.
 *
 * NOTHING ABOUT SIGNING UP DEPENDS ON THE PRICE LIST LOADING. If
 * fn_signup_plans cannot be read the number is still asked, the form still
 * submits, and the school is told it will see its plan inside. A form that
 * refuses a customer because a read failed turns them away silently.
 *
 * THE ACCOUNT IS CREATED HERE, and the school lands in the app. There is no
 * second screen to abandon: the term chosen here goes with the signup, and it
 * can be changed later from Your plan.
 *
 * REGION IS ABOVE CITY, not beside it. The product is sold by province, and
 * city alone does not answer which one: "Model Town" is in three of them. The
 * list comes from the database through fn_signup_regions, so the form and the
 * check constraint on schools.region cannot disagree about a spelling and
 * refuse a signup at its last step.
 */
export function Signup() {
  const navigate = useNavigate()
  const { signIn } = useAuth()
  const [form, setForm] = useState({
    school_name: '', full_name: '', email: '', phone: '',
    region: '', city: '', password: '', students: '',
  })
  const [term, setTerm] = useState<Term>(1)
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

  const plans = useQuery({ queryKey: ['signupPlans'], queryFn: listSignupPlans })
  const pupils = pupilsFrom(form.students)
  const plan = pupils === null ? null : planForStudents(plans.data ?? [], pupils)
  // The term is sent only for a plan that has it. Enterprise has no terms
  // until its price is agreed, and a list that failed to load has none either.
  const sendTerm: Term = plan && !plan.by_arrangement && plan.terms.some((t) => t.months === term) ? term : 1

  const set = (k: keyof typeof form) =>
    (e: React.ChangeEvent<HTMLInputElement | HTMLSelectElement>) =>
      setForm((f) => ({ ...f, [k]: e.target.value }))

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (pupils === null) {
      setError(`Enter the number of pupils on your roll, a whole number from 1 to ${MOST_PUPILS.toLocaleString('en-PK')}.`)
      return
    }
    setBusy(true)
    setError(null)
    try {
      const sb = requireSupabase()
      const { students: _typed, ...details } = form
      const { data, error: fnErr } = await sb.functions.invoke('signup-school', {
        body: { ...details, students: pupils, term_months: sendTerm },
      })
      if (fnErr) {
        // THE FUNCTION'S OWN WORDS, not the client's. A refusal arrives as a
        // 400 whose body says what to do ("That email address already has an
        // account", "a school that size is set up by us"), and the client's
        // message for any 400 is "Edge Function returned a non-2xx status
        // code", which tells a school owner nothing.
        let msg = fnErr.message
        try {
          const body = await (fnErr as unknown as {
            context?: { json?: () => Promise<{ error?: string }> }
          }).context?.json?.()
          if (body?.error) msg = body.error
        } catch { /* keep the client's message */ }
        throw new Error(msg)
      }
      if (data?.error) throw new Error(data.error)

      const { error: signInErr } = await signIn(form.email.trim(), form.password)
      if (signInErr) {
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

  const typedBadly = form.students.trim() !== '' && pupils === null

  return (
    <AuthLayout
      door={{ ...SIGNUP_DOOR, line: 'Fourteen days free, on the plan your roll puts you on.' }}
      schoolName={form.school_name}
    >
      <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">
        Start your free trial
      </h1>
      <p className="mt-1.5 text-base text-slate-500">
        14 days free. No card needed: pay by bank transfer only if you decide to continue.
      </p>

      <form onSubmit={onSubmit} className="mt-6 space-y-4" aria-busy={busy}>
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


        {/* THE NUMBER, AND WHAT IT MEANS, LAST BEFORE THE BUTTON. The details
            above are typed without thinking; this is the one answer that sets
            what the school will pay, so it sits where the eye is when the
            button is pressed, with its consequence directly under it. */}
        <div className="border-t border-slate-200 pt-4">
          <label className="block">
            <span className={authLabel}>How many pupils are on your roll?</span>
            <input
              type="number"
              inputMode="numeric"
              min={1}
              max={MOST_PUPILS}
              step={1}
              required
              value={form.students}
              onChange={set('students')}
              className={authField}
              aria-describedby="pupils-hint"
              aria-invalid={typedBadly}
            />
          </label>
          <p id="pupils-hint" className={typedBadly ? 'mt-1.5 block text-sm text-danger-700' : authHint}>
            {typedBadly
              ? `Enter a whole number from 1 to ${MOST_PUPILS.toLocaleString('en-PK')}.`
              : 'Every child enrolled today. Your plan follows from this number.'}
          </p>
          <YourPlan
            plans={plans.data ?? []}
            loading={plans.isLoading}
            failed={plans.isError}
            pupils={pupils}
            plan={plan}
            term={sendTerm}
            onTerm={setTerm}
          />
        </div>

        {error && <AuthError>{error}</AuthError>}

        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Creating your school' : 'Start my free trial'}
        </button>

        {/* THE LAST WORD BEFORE THE BUTTON IS WHAT IS NOT HAPPENING. */}
        <p className="text-center text-xs text-slate-500">
          {plan?.by_arrangement
            ? 'Nothing is charged today and no card is needed. We agree your price with you during the trial.'
            : 'Nothing is charged today and no card is needed. You can change how often you pay at any time.'}
        </p>
      </form>

      <p className="mt-5 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        Already have an account?{' '}
        <Link to="/login" className="font-medium text-brand-700 hover:underline">Sign in</Link>
      </p>
    </AuthLayout>
  )
}

function upTo(p: SignupPlan): string {
  return p.student_limit === null
    ? `more than ${(p.min_students - 1).toLocaleString('en-PK')} pupils`
    : `up to ${p.student_limit.toLocaleString('en-PK')} pupils`
}

/**
 * What the number on the form puts the school on, said as it is typed.
 *
 * Polite live region, so a screen reader hears the plan change when the
 * number crosses 280 or 1,000 without the focus moving off the field.
 *
 * Exported for tools/signup-flow-preview.test.tsx, which renders each state of
 * it: a static render cannot type a number into the form around it.
 */
export function YourPlan({ plans, loading, failed, pupils, plan, term, onTerm }: {
  plans: SignupPlan[]; loading: boolean; failed: boolean
  pupils: number | null; plan: SignupPlan | null
  term: Term; onTerm: (t: Term) => void
}) {
  let body: React.ReactNode
  if (pupils === null) {
    if (plans.length === 0) return null
    body = (
      <p className="text-sm text-slate-600">
        {plans.map((p, i) => (
          <span key={p.code}>
            {i > 0 && (i === plans.length - 1 ? ' and ' : ', ')}
            <span className="font-medium text-slate-800">{p.name}</span> {p.by_arrangement ? 'for' : 'is for'} {upTo(p)}
          </span>
        ))}.
      </p>
    )
  } else if (loading) {
    body = <p className="text-sm text-slate-500">Finding your plan…</p>
  } else if (!plan) {
    // The price list did not load, or came from a database that does not
    // know the pupil ranges yet. The school can still sign up.
    body = (
      <p className="text-sm text-slate-600">
        {failed ? 'We could not load the plans just now. ' : ''}You can still start your trial: your
        plan follows from this number, and you will see it and its price inside.
      </p>
    )
  } else if (plan.by_arrangement) {
    body = (
      <>
        <PlanName plan={plan} />
        <p className="mt-2 text-sm text-slate-700">
          <span className="font-medium text-slate-900">Priced with you:</span> we agree a monthly price
          with you during your free trial; three months is 10% off and a year is two months free.
        </p>
        <p className="mt-2 text-sm text-slate-700">
          Your trial is 14 days. The software locks at the end of the trial until the price is agreed.
        </p>
      </>
    )
  } else {
    const chosen = plan.terms.find((t) => t.months === term) ?? plan.terms[0]
    body = (
      <>
        <PlanName plan={plan} />
        <fieldset className="mt-3">
          <legend className="text-sm font-medium text-slate-700">How often will you pay?</legend>
          <div className="mt-2 grid gap-2 sm:grid-cols-3">
            {plan.terms.map((t) => {
              const on = t.months === term
              return (
                <label key={t.months}
                  className={`cursor-pointer rounded-lg border p-2.5 text-left transition has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand-500 has-[:focus-visible]:ring-offset-1 ${
                    on ? 'border-brand-600 bg-brand-600 text-white'
                       : 'border-slate-300 bg-white text-slate-700 hover:border-slate-400'}`}>
                  <input type="radio" name="term" value={t.months} checked={on}
                    onChange={() => onTerm(t.months)} className="sr-only" />
                  <span className="block text-sm font-semibold">{TERM_LABEL[t.months]}</span>
                  <span className={`block text-sm tabular-nums ${on ? 'text-white' : 'text-slate-900'}`}>
                    {formatPkr(t.amount)}
                  </span>
                  {/* IN RUPEES, NOT AS A PERCENTAGE. "Save Rs 4,000" is a
                      number a school can weigh; "16.7 percent" is homework. */}
                  <span className={`block text-xs ${on ? 'text-brand-100' : t.saving > 0 ? 'text-money-700' : 'text-slate-500'}`}>
                    {t.saving > 0 ? `save ${formatPkr(t.saving)}` : 'no saving'}
                  </span>
                </label>
              )
            })}
          </div>
        </fieldset>
        {chosen && (
          <p className="mt-2 text-sm text-slate-700">
            After your 14 days free, your first invoice is{' '}
            <span className="font-semibold tabular-nums text-slate-900">{formatPkr(chosen.amount)}</span>{' '}
            for {chosen.months === 1 ? 'one month' : chosen.months === 12 ? 'a year' : `${chosen.months} months`}.
          </p>
        )}
      </>
    )
  }
  return (
    <div className="mt-3 rounded-xl border border-slate-200 bg-slate-50 p-3.5" aria-live="polite">
      {body}
    </div>
  )
}

function PlanName({ plan }: { plan: SignupPlan }) {
  return (
    <p className="text-sm text-slate-700">
      Your plan: <span className="text-base font-semibold text-slate-900">{plan.name}</span>,{' '}
      {plan.student_limit === null ? 'no pupil limit' : `for up to ${plan.student_limit.toLocaleString('en-PK')} pupils`}.
    </p>
  )
}

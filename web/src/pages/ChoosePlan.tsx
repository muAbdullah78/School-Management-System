import { useEffect, useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { useSchoolName } from '@/hooks/useSchoolName'
import { fetchLicence, formatPkr } from '@/lib/licence'
import {
  TERM_LABEL, applyDiscount, chooseMyPlan, listSignupPlans, previewDiscount,
  termSentence, type DiscountPreview, type SignupPlan,
} from '@/lib/plans'
import { PRODUCT_NAME } from '@/lib/config'
import { IconCheck, IconAlert } from '@/components/icons'
import { LoadError } from '@/components/ui'

/**
 * Step two: which plan, how often, and the invoice it produces.
 *
 * WHY THE INVOICE IS ON THE SCREEN AT ALL. The old chooser showed three cards
 * and three buttons and left the buyer to work out what any of it meant for
 * them. What a school actually wants to know before it commits is one thing:
 * what will I be charged, and when. That is an invoice, so this shows an
 * invoice, built from the same numbers the first real one will be built from.
 *
 * IT IS NOT A MOCKUP AND NOT AN ESTIMATE. Every figure on it comes from
 * fn_signup_plans, which is fn__plan_price, which is the function that prices
 * the first invoice. A browser reimplementation of that arithmetic would agree
 * with the invoice right up until somebody changed one of the nine rates, and
 * then this screen would quote a figure the first invoice contradicts, on the
 * screen where a school decides to buy.
 *
 * NOTHING HERE TAKES MONEY OR RAISES AN INVOICE. fn_my_choose_plan writes the
 * plan and the term and nothing else; the first invoice is raised after the
 * trial ends, by the renewal run. The panel says so in those words, because
 * "Upcoming invoice" beside a button is exactly the shape of thing a person
 * expects to be charged by.
 *
 * REACHED FROM TWO PLACES and it has to work the same from both: straight after
 * signup, where it is step two of two, and from Settings afterwards, where it
 * is "change my plan". The only difference is the line at the top and where
 * Continue goes, both of which are derived from whether the school is still
 * trialing rather than from how the user arrived.
 */
export function ChoosePlan() {
  const navigate = useNavigate()
  const { profile } = useAuth()
  const schoolName = useSchoolName()

  const plans = useQuery({ queryKey: ['signupPlans'], queryFn: listSignupPlans })
  const licence = useQuery({ queryKey: ['licence'], queryFn: fetchLicence })

  const [picked, setPicked] = useState<string | null>(null)
  const [term, setTerm] = useState<number | null>(null)
  const [code, setCode] = useState('')
  const [preview, setPreview] = useState<DiscountPreview | null>(null)
  const [checking, setChecking] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const lic = licence.data?.ok ? licence.data : null
  const trialing = lic?.status === 'trialing'

  // DERIVED, NOT SET BY AN EFFECT, for the reason the old chooser learned the
  // hard way: an effect that fills these in after the first render leaves the
  // invoice panel showing a no-plan fallback on the first paint. `picked` and
  // `term` only ever hold a deliberate choice; until one is made, the school's
  // existing plan and term are what is shown, which is what it is actually on.
  const chosen: SignupPlan | null = useMemo(() => {
    const list = plans.data ?? []
    return list.find((p) => p.code === picked)
      ?? list.find((p) => p.code === lic?.plan_code)
      ?? list[0] ?? null
  }, [plans.data, picked, lic?.plan_code])

  const months = term ?? lic?.term_months ?? 1
  const chosenTerm = chosen?.terms.find((x) => x.months === months)
    ?? chosen?.terms.find((x) => x.months === 1)
    ?? null
  const listAmount = chosenTerm?.amount ?? 0

  // A code that was valid for Starter yearly may not be valid for Growth
  // monthly, so the preview is re-asked whenever either changes rather than
  // left on screen saying something that is no longer true. Cleared first, so
  // there is never a moment where an old answer sits under a new plan.
  useEffect(() => {
    if (!preview?.ok || !chosen) return
    let live = true
    void previewDiscount(preview.code ?? code, chosen.code, months)
      .then((p) => { if (live) setPreview(p) })
      .catch(() => { if (live) setPreview(null) })
    return () => { live = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chosen?.code, months])

  const discount = preview?.ok ? (preview.discount_amount ?? 0) : 0
  const trialDays = preview?.ok && preview.kind === 'trial_days'
    ? (preview.trial_days ?? 0) : 0
  const payable = Math.max(listAmount - discount, 0)

  async function check() {
    const c = code.trim()
    if (!c || !chosen) return
    setChecking(true)
    setError(null)
    try {
      setPreview(await previewDiscount(c, chosen.code, months))
    } catch (e) {
      setError((e as Error).message)
    }
    setChecking(false)
  }

  async function onContinue() {
    if (!chosen) return
    setBusy(true)
    setError(null)
    try {
      // THE PLAN FIRST, AND THAT ORDER IS LOAD BEARING. fn_my_apply_discount
      // checks the code against the plan and term the school is ON, so a code
      // restricted to yearly Growth has to be redeemed after the move to
      // yearly Growth and not before it.
      await chooseMyPlan(chosen.code, months)
      if (preview?.ok && preview.code) await applyDiscount(preview.code)
      navigate('/', { replace: true })
    } catch (e) {
      setError((e as Error).message)
      setBusy(false)
    }
  }

  const today = new Date().toLocaleDateString('en-GB',
    { day: '2-digit', month: 'short', year: 'numeric' })
  const trialEnds = lic?.expires_on
    ? new Date(lic.expires_on).toLocaleDateString('en-GB',
        { day: '2-digit', month: 'short', year: 'numeric' })
    : null

  if (plans.isLoading || licence.isLoading) {
    return <div className="flex min-h-full items-center justify-center p-8 text-slate-500">Loading…</div>
  }

  /* A PRICE THAT DID NOT LOAD MUST NOT BE DRAWN AS A PRICE.
   *
   * The first version of this screen rendered its invoice panel whatever
   * happened, so a failed read of the price list produced a complete, confident
   * "Due at your next renewal: Rs 0" on the one screen in the product where a
   * school decides to buy. Nothing on it was marked as missing; it simply said
   * zero. The page smoke suite caught it, which is exactly what that suite is
   * for: a failed read that looks like an empty list is how somebody comes to
   * trust a number that was never loaded.
   *
   * So the whole screen stops. Not a partial render with a banner over it: the
   * plan cards are priced too, and half a price list is a worse thing to choose
   * from than none. The school loses nothing by waiting, because its trial is
   * already running and its plan is already set. */
  if (plans.isError || licence.isError) {
    return (
      <div className="min-h-full bg-slate-50 p-6">
        <div className="mx-auto max-w-lg">
          <LoadError of={[plans, licence]} what="The plans and prices" />
          <p className="text-sm text-slate-600">
            Nothing has changed and nothing is charged. Your free trial is
            running either way, and you can come back to this screen from
            Settings at any time.
          </p>
          <button
            type="button"
            onClick={() => { void plans.refetch(); void licence.refetch() }}
            className="mt-4 rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Try again
          </button>
        </div>
      </div>
    )
  }

  return (
    <div className="min-h-full bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex h-16 max-w-5xl items-center justify-between gap-3 px-4 sm:px-6">
          <span className="truncate text-[15px] font-semibold tracking-[-0.01em] text-slate-900">
            {schoolName || PRODUCT_NAME}
          </span>
          {trialing && (
            <span className="shrink-0 text-sm font-medium text-slate-500">Step 2 of 2</span>
          )}
        </div>
      </header>

      <main className="mx-auto max-w-5xl px-4 py-8 sm:px-6 lg:grid lg:grid-cols-[minmax(0,1fr)_360px] lg:gap-10">
        {/* ------------------------------------------------------- choosing -- */}
        <section>
          <h1 className="text-2xl font-semibold tracking-[-0.015em] text-slate-900">
            {trialing ? 'Choose your plan' : 'Change your plan'}
          </h1>
          <p className="mt-1.5 text-base text-slate-500">
            {trialing
              ? 'Nothing is charged today. Pick what fits and you can change it later.'
              : 'How often you pay takes effect at your next renewal.'}
          </p>

          <fieldset className="mt-6">
            <legend className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              How many children do you have?
            </legend>
            <div className="mt-2.5 space-y-2">
              {(plans.data ?? []).map((p) => {
                const on = p.code === chosen?.code
                const monthly = p.terms.find((x) => x.months === 1)
                return (
                  <label
                    key={p.code}
                    className={`flex cursor-pointer items-center justify-between gap-3 rounded-xl border p-4 transition ${
                      on ? 'border-brand-600 bg-white ring-1 ring-brand-600 shadow-card'
                         : 'border-slate-200 bg-white hover:border-slate-300'}`}
                  >
                    <input type="radio" name="plan" value={p.code} checked={on}
                      onChange={() => setPicked(p.code)} className="sr-only" />
                    <span className="min-w-0">
                      <span className="block text-base font-semibold text-slate-900">
                        {p.name.replace(/\s*\(.*$/, '')}
                      </span>
                      <span className="block text-sm text-slate-500">
                        {p.student_limit === null
                          ? 'any number of children'
                          : `up to ${p.student_limit.toLocaleString()} children`}
                      </span>
                    </span>
                    <span className="shrink-0 text-right">
                      {monthly && (
                        <span className="block text-sm font-medium tabular-nums text-slate-900">
                          from {formatPkr(monthly.amount)}
                        </span>
                      )}
                      <span className="block text-xs text-slate-500">a month</span>
                    </span>
                  </label>
                )
              })}
            </div>
          </fieldset>

          <fieldset className="mt-6">
            <legend className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              How often will you pay?
            </legend>
            <div className="mt-2.5 grid gap-2 sm:grid-cols-3">
              {(chosen?.terms ?? []).map((x) => {
                const on = x.months === months
                return (
                  <label
                    key={x.months}
                    className={`cursor-pointer rounded-xl border p-3 text-left transition ${
                      on ? 'border-brand-600 bg-brand-600 text-white'
                         : 'border-slate-200 bg-white text-slate-700 hover:border-slate-300'}`}
                  >
                    <input type="radio" name="term" value={x.months} checked={on}
                      onChange={() => setTerm(x.months)} className="sr-only" />
                    <span className="block text-sm font-semibold">
                      {TERM_LABEL[x.months] ?? `${x.months} months`}
                    </span>
                    <span className={`block text-sm tabular-nums ${on ? 'text-brand-100' : 'text-slate-600'}`}>
                      {formatPkr(x.amount)}
                    </span>
                    {/* IN RUPEES, NOT AS A PERCENTAGE. A saving stated as
                        "16.7 percent" is homework; one stated as "Rs 4,000" is
                        a number a school can weigh against something it wants. */}
                    {x.saving > 0 && (
                      <span className={`block text-xs ${on ? 'text-brand-100' : 'text-money-700'}`}>
                        save {formatPkr(x.saving)}
                      </span>
                    )}
                  </label>
                )
              })}
            </div>
          </fieldset>
        </section>

        {/* -------------------------------------------------- the invoice -- */}
        <aside className="mt-8 lg:mt-0">
          <div className="rounded-2xl border border-slate-200 bg-white p-5 shadow-card lg:sticky lg:top-8">
            <div className="flex items-baseline justify-between gap-3">
              <h2 className="text-sm font-semibold uppercase tracking-wide text-slate-500">
                Upcoming invoice
              </h2>
              <span className="shrink-0 text-xs text-slate-400 tabular-nums">{today}</span>
            </div>

            <dl className="mt-4 space-y-1.5 border-b border-slate-100 pb-4 text-sm">
              <div className="flex justify-between gap-3">
                <dt className="text-slate-500">School</dt>
                <dd className="min-w-0 truncate text-right font-medium text-slate-900">
                  {schoolName || '-'}
                </dd>
              </div>
              <div className="flex justify-between gap-3">
                <dt className="text-slate-500">In the name of</dt>
                <dd className="min-w-0 truncate text-right text-slate-700">
                  {profile?.full_name ?? '-'}
                </dd>
              </div>
              {trialEnds && (
                <div className="flex justify-between gap-3">
                  <dt className="text-slate-500">Free trial ends</dt>
                  <dd className="text-right tabular-nums text-slate-700">{trialEnds}</dd>
                </div>
              )}
            </dl>

            <dl className="mt-4 space-y-2 text-sm">
              <div className="flex justify-between gap-3">
                <dt className="min-w-0 text-slate-700">
                  {chosen?.name.replace(/\s*\(.*$/, '') ?? 'Plan'}
                  <span className="block text-xs text-slate-500">
                    billed {termSentence(months)}
                  </span>
                </dt>
                <dd className="shrink-0 tabular-nums text-slate-900">{formatPkr(listAmount)}</dd>
              </div>

              {discount > 0 && (
                <div className="flex justify-between gap-3 text-money-700">
                  <dt className="min-w-0">
                    Discount
                    <span className="block text-xs">{preview?.code}</span>
                  </dt>
                  <dd className="shrink-0 tabular-nums">-{formatPkr(discount)}</dd>
                </div>
              )}
            </dl>

            <div className="mt-4 flex items-baseline justify-between gap-3 border-t border-slate-200 pt-4">
              <span className="text-sm font-semibold text-slate-900">
                {trialing ? 'Due after your trial' : 'Due at your next renewal'}
              </span>
              <span className="text-xl font-semibold tabular-nums text-slate-900">
                {formatPkr(payable)}
              </span>
            </div>

            {/* THE SENTENCE THAT KEEPS THIS HONEST. A panel headed "Upcoming
                invoice" next to a button is exactly the shape of thing somebody
                expects to be charged by. */}
            <p className="mt-2 text-xs text-slate-500">
              {trialing
                ? `Nothing is charged today and no card is needed.${
                    trialEnds ? ` The first invoice is raised after ${trialEnds}.` : ''}`
                : 'Nothing is charged today. This takes effect at your next renewal.'}
            </p>

            {trialDays > 0 && (
              <p className="mt-2 rounded-lg bg-money-50 px-3 py-2 text-xs text-money-800 ring-1 ring-money-100">
                {preview?.summary}. Your trial is extended when you continue.
              </p>
            )}

            {/* ------------------------------------------------ the code -- */}
            <div className="mt-5 border-t border-slate-100 pt-4">
              <label className="block">
                <span className="text-xs font-semibold uppercase tracking-wide text-slate-500">
                  Discount code
                </span>
                <div className="mt-1.5 flex gap-2">
                  <input
                    value={code}
                    onChange={(e) => { setCode(e.target.value.toUpperCase()); setPreview(null) }}
                    onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void check() } }}
                    placeholder="If you were given one"
                    autoCapitalize="characters"
                    spellCheck={false}
                    className="min-w-0 flex-1 rounded-lg border border-slate-300 px-3 py-2 text-sm uppercase tracking-wide text-slate-900 placeholder:normal-case placeholder:tracking-normal placeholder:text-slate-400 focus:border-brand-600 focus:outline-none focus:ring-2 focus:ring-brand-500/30"
                  />
                  <button
                    type="button"
                    onClick={() => void check()}
                    disabled={!code.trim() || checking}
                    className="shrink-0 rounded-lg border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                  >
                    {checking ? 'Checking…' : 'Apply'}
                  </button>
                </div>
              </label>

              {/* A REFUSAL IS AN ANSWER, NOT AN ERROR. "That code expired on
                  03 Sep 2026" is an ordinary reply to an ordinary question, and
                  a red banner for somebody who typed a code they were handed is
                  the wrong shape of feedback entirely. */}
              {preview && !preview.ok && (
                <p className="mt-2 flex items-start gap-1.5 text-xs text-due-800">
                  <IconAlert className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                  <span>{preview.reason}</span>
                </p>
              )}
              {preview?.ok && (
                <p className="mt-2 flex items-start gap-1.5 text-xs text-money-700">
                  <IconCheck className="mt-0.5 h-3.5 w-3.5 shrink-0" />
                  <span>{preview.summary}.</span>
                </p>
              )}
            </div>

            {error && (
              <p className="mt-4 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700 ring-1 ring-danger-100">
                {error}
              </p>
            )}

            <button
              type="button"
              onClick={() => void onContinue()}
              disabled={busy || !chosen}
              className="mt-5 flex min-h-[44px] w-full items-center justify-center rounded-lg bg-brand-600 px-4 py-2.5 text-base font-semibold text-white shadow-raised hover:bg-brand-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 disabled:opacity-70"
            >
              {busy ? 'Saving…' : trialing ? 'Start my trial' : 'Save this plan'}
            </button>

            {trialing && (
              <button
                type="button"
                onClick={() => navigate('/', { replace: true })}
                className="mt-2 w-full rounded-lg px-4 py-2 text-sm text-slate-500 hover:text-slate-800"
              >
                Decide later
              </button>
            )}
          </div>
        </aside>
      </main>
    </div>
  )
}

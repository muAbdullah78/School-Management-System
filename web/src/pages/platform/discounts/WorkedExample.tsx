import { useState, type ReactNode } from 'react'
import type { DiscountTerms } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'
import { discountCalc, planNames, termPrice, termWord, type PricedPlan } from './rules'

const TERMS = [1, 3, 12] as const

/** "10% for 3 months", "Rs 500 off each month until 31 Mar 2027". */
export function shortTerms(t: DiscountTerms): string {
  const what = t.kind === 'percent' ? `${Number(t.value)}%`
    : t.kind === 'flat' ? `${formatPkr(Number(t.value))} off each month`
    : `${Number(t.value)} extra trial days`
  if (t.kind === 'trial_days') return what
  if (t.duration === 'months') {
    const n = t.duration_months ?? 0
    return `${what} for ${n} month${n === 1 ? '' : 's'}`
  }
  if (t.duration === 'until') return `${what} until ${fmtDate(t.duration_until)}`
  return `${what} for as long as they subscribe`
}

/**
 * What a code would take off, worked out on the price list before it exists.
 *
 * WHY EVERY TERM AND NOT ONE INVOICE. A code counts billed months, and that is
 * the one thing about it nobody guesses right: "10% for 3 months" is three
 * monthly invoices, one quarterly invoice, or a quarter of one yearly invoice,
 * and the yearly figure surprises people. Showing the three side by side is
 * what makes the rule visible before a school reads it on an invoice.
 *
 * THE FIGURES COME FROM THE DATABASE'S PRICE LIST (fn_platform_price_list) and
 * the arithmetic is fn__discount_calc's, so what is shown here is what the
 * first invoice would say. Enterprise has no list price and is left out: a
 * figure for it would be a figure we made up.
 */
export function WorkedExample({ terms, code, plans, start }: {
  terms: DiscountTerms
  code: string
  plans: PricedPlan[]
  /** The day the example invoices start: today. */
  start: string
}) {
  const [pick, setPick] = useState('')
  const value = Number(terms.value)

  let body: ReactNode
  if (terms.kind === 'trial_days') {
    body = (
      <p>
        Adds {Number.isFinite(value) && value > 0 ? value : 'some'} day(s) to the free trial of a
        school that is still in its trial, once per school. Nothing comes off an invoice, and it
        does not take the place of a money code the school has.
      </p>
    )
  } else if (!Number.isFinite(value) || value <= 0) {
    body = <p>Fill in the amount to see what it takes off.</p>
  } else {
    const eligible = plans.filter((p) => p.active
      && (!terms.plan_codes || terms.plan_codes.includes(p.code)))
    const priced = eligible.filter((p) => termPrice(p, 1) != null)
    const plan = priced.find((p) => p.code === pick) ?? priced[0]
    const byArrangement = eligible.some((p) => p.by_arrangement)

    if (!plan) {
      body = plans.length === 0
        ? <p>The price list has not loaded, so there is no example yet.</p>
        : eligible.length === 0
        ? <p>None of the plans it is for is on sale, so no school could use it.</p>
        : (
          <p>
            {planNames(eligible.map((p) => p.code), plans)} is priced with each
            school, so what this takes off depends on the price agreed with them:{' '}
            {terms.kind === 'percent'
              ? `${value}% of the months it covers.`
              : `${formatPkr(value)} off each month it covers.`}
          </p>
        )
    } else {
      const phrase = shortTerms(terms)
      const lines = TERMS.map((n) => {
        const price = termPrice(plan, n)
        if (price == null) return null
        const head = `On a ${termWord(n)} ${plan.name} invoice (${formatPkr(price)})`
        if (terms.min_term_months && n < terms.min_term_months) {
          return `${head}, it does not apply: it is for paying ${terms.min_term_months} months or more at a time.`
        }
        const r = discountCalc({
          code: code || 'this code', kind: terms.kind, value,
          duration: terms.duration, monthsLeft: terms.duration_months ?? null,
          until: terms.duration_until ?? null, planCodes: terms.plan_codes ?? null,
          minTerm: terms.min_term_months ?? null,
        }, {
          planCode: plan.code, planNames: planNames(terms.plan_codes, plans),
          months: n, start, termPrice: price,
        })
        if (r.covered === 0) {
          return `${head}, it does not apply: no billed month of that invoice starts by its end date.`
        }
        const months = n === 1 ? 'its one billed month' : `${r.covered} of its ${n} billed months`
        let tail = ''
        if (terms.duration === 'months') {
          const left = (terms.duration_months ?? 0) - r.covered
          tail = left > 0
            ? ` The other ${left} month${left === 1 ? '' : 's'} come off the invoices after it.`
            : ' That uses the code up.'
        }
        return `${head}, ${phrase} covers ${months} and takes ${formatPkr(r.amount)} off. `
          + `The school pays ${formatPkr(price - r.amount)}.${tail}`
      }).filter((l): l is string => !!l)

      body = (
        <>
          {priced.length > 1 && (
            <label className="mb-2 flex items-center gap-2">
              <span className="text-xs font-medium text-slate-600">Work it out on</span>
              <select value={plan.code} onChange={(e) => setPick(e.target.value)}
                className="rounded border border-slate-300 bg-white px-2 py-1 text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500">
                {priced.map((p) => <option key={p.code} value={p.code}>{p.name}</option>)}
              </select>
            </label>
          )}
          <ul className="list-disc space-y-1 pl-4">
            {lines.map((l) => <li key={l}>{l}</li>)}
          </ul>
          <p className="mt-2 text-slate-500">
            A code counts billed months. A monthly invoice bills 1, a 3-month invoice 3 and a
            yearly invoice 12; the code takes its share of exactly the months it covers.
            {terms.duration === 'until' && ` Worked out for invoices starting ${fmtDate(start)}.`}
            {byArrangement && ' On Enterprise it works the same way on the price agreed with the school.'}
          </p>
        </>
      )
    }
  }

  return (
    <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-700"
      aria-live="polite">
      <p className="mb-1 font-medium text-slate-800">Worked example, from our price list</p>
      {body}
    </div>
  )
}

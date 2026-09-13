import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  deleteDiscount, listDiscountUsage, listDiscounts, listPlans, revokeDiscount,
  saveDiscount, type DiscountCode, type DiscountDuration, type DiscountKind,
  type SaveDiscountInput,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDate, fmtDateTime } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'
const LABEL = 'block text-xs font-medium text-slate-600'

/**
 * The discount engine, from the vendor's side.
 *
 * TWO PANELS AND THEY ANSWER DIFFERENT QUESTIONS. The codes are what is on
 * offer; the roster is who actually took one and whether it is still doing
 * anything. Before this existed the only record of a discount was prose in an
 * invoice note, so "which schools are on a discount" had no answer at all.
 *
 * THE ROSTER IS NOT A LIST OF CODES WITH SCHOOLS UNDER THEM. It is a list of
 * schools, newest first, because the question an operator is actually asking is
 * about a school: "is this one still on the twenty percent we gave them in
 * April". A code-first tree makes that a search.
 *
 * FOUR STATES, AND THE DATABASE DECIDES WHICH. Active, spent, expired, removed.
 * They are computed in fn_platform_discount_usage rather than here, because
 * "expired" is a comparison against today and a browser in a different timezone
 * would draw a different conclusion from the same row.
 *
 * EDITING A CODE NEVER REACHES A SCHOOL ALREADY ON IT, and the form says so
 * when it matters. The terms are copied onto the redemption, which is the whole
 * design: a promise a school was given cannot be edited underneath them.
 */
export function Discounts() {
  const qc = useQueryClient()
  const codes = useQuery({ queryKey: ['discounts'], queryFn: listDiscounts })
  const usage = useQuery({ queryKey: ['discountUsage'], queryFn: () => listDiscountUsage() })
  const plans = useQuery({ queryKey: ['plans'], queryFn: listPlans })
  const [editing, setEditing] = useState<DiscountCode | null | 'new'>(null)
  const [taking, setTaking] = useState<{ id: string; name: string } | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const refresh = () => {
    void qc.invalidateQueries({ queryKey: ['discounts'] })
    void qc.invalidateQueries({ queryKey: ['discountUsage'] })
  }

  const del = useMutation({
    mutationFn: deleteDiscount,
    onSuccess: () => { setErr(null); refresh() },
    onError: (e: Error) => setErr(e.message),
  })

  const revoke = useMutation({
    mutationFn: (v: { id: string; reason: string }) => revokeDiscount(v.id, v.reason),
    onSuccess: () => { setErr(null); refresh() },
    onError: (e: Error) => setErr(e.message),
  })

  const live = useMemo(
    () => (usage.data ?? []).filter((u) => u.state === 'active'),
    [usage.data])

  return (
    <div className="space-y-6">
      {err && (
        <p className="rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {err}
        </p>
      )}

      {/* ------------------------------------------------------- the codes -- */}
      <section className="rounded-lg border border-slate-200 bg-white">
        <header className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-200 px-4 py-3">
          <div>
            <h2 className="text-sm font-semibold text-slate-800">Discount codes</h2>
            <p className="text-xs text-slate-500">
              What is on offer. Editing one never changes what a school already on
              it was promised.
            </p>
          </div>
          <button
            onClick={() => { setErr(null); setEditing('new') }}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700"
          >
            New code
          </button>
        </header>

        {codes.isLoading && <p className="p-4 text-sm text-slate-400">Loading…</p>}
        {codes.isError && (
          <p className="p-4 text-sm text-danger-600">{(codes.error as Error).message}</p>
        )}
        {codes.data?.length === 0 && (
          <p className="p-4 text-sm text-slate-500">
            No codes yet. Every deal is currently a figure typed into one invoice,
            which nothing carries to the next one.
          </p>
        )}

        {!!codes.data?.length && (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[46rem] text-sm">
              <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 font-medium">Code</th>
                  <th className="px-3 py-2 font-medium">What it does</th>
                  <th className="px-3 py-2 font-medium">Can be used</th>
                  <th className="px-3 py-2 text-right font-medium">Taken up</th>
                  <th className="px-3 py-2 text-right font-medium">Given away</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {codes.data.map((c) => (
                  <tr key={c.code} className="border-b border-slate-100 last:border-0">
                    <td className="px-3 py-2.5">
                      <span className="font-mono font-medium text-slate-900">{c.code}</span>
                      {!c.active && (
                        <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600">
                          off
                        </span>
                      )}
                      <span className="block text-xs text-slate-500">{c.description}</span>
                    </td>
                    <td className="px-3 py-2.5 text-slate-700">
                      {c.summary}
                      {(c.plan_codes || c.min_term_months) && (
                        <span className="block text-xs text-slate-500">
                          {c.plan_codes ? `${c.plan_codes.join(' or ')} only` : ''}
                          {c.plan_codes && c.min_term_months ? ', ' : ''}
                          {c.min_term_months ? `${c.min_term_months}+ month term` : ''}
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-2.5 text-xs text-slate-600">
                      {c.redeem_from || c.redeem_until
                        ? `${c.redeem_from ? fmtDate(c.redeem_from) : 'any time'} to ${
                            c.redeem_until ? fmtDate(c.redeem_until) : 'no end'}`
                        : 'any time'}
                      {c.max_redemptions != null && (
                        <span className="block">
                          {c.redeemed} of {c.max_redemptions} seats used
                        </span>
                      )}
                    </td>
                    <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
                      {c.redeemed}
                      <span className="block text-xs text-slate-500">{c.live} live</span>
                    </td>
                    <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
                      {formatPkr(c.total_saved)}
                    </td>
                    <td className="px-3 py-2.5 text-right">
                      <button
                        onClick={() => { setErr(null); setEditing(c) }}
                        className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                      >
                        Edit
                      </button>
                      {/* DELETE ONLY WHILE NOBODY HAS USED IT. Once a school
                          has redeemed a code it is part of their billing record,
                          so the button is not offered rather than offered and
                          refused. The database refuses it too. */}
                      {c.deletable && (
                        <button
                          onClick={() => del.mutate(c.code)}
                          className="ml-1.5 rounded border border-danger-200 px-2 py-1 text-xs font-medium text-danger-700 hover:bg-danger-50"
                        >
                          Delete
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* ------------------------------------------------------ the roster -- */}
      <section className="rounded-lg border border-slate-200 bg-white">
        <header className="border-b border-slate-200 px-4 py-3">
          <h2 className="text-sm font-semibold text-slate-800">
            Who is on a discount
            {live.length > 0 && (
              <span className="ml-2 rounded-full bg-money-100 px-2 py-0.5 text-xs font-medium text-money-800">
                {live.length} live
              </span>
            )}
          </h2>
          <p className="text-xs text-slate-500">
            Every school that has ever redeemed a code, newest first, and whether
            it is still getting anything from it.
          </p>
        </header>

        {usage.isLoading && <p className="p-4 text-sm text-slate-400">Loading…</p>}
        {usage.data?.length === 0 && (
          <p className="p-4 text-sm text-slate-500">Nobody has used a code yet.</p>
        )}

        {!!usage.data?.length && (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[44rem] text-sm">
              <thead className="border-b border-slate-200 bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2 font-medium">School</th>
                  <th className="px-3 py-2 font-medium">Code</th>
                  <th className="px-3 py-2 font-medium">State</th>
                  <th className="px-3 py-2 font-medium">Since</th>
                  <th className="px-3 py-2 text-right font-medium">Used</th>
                  <th className="px-3 py-2 text-right font-medium">Worth</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {usage.data.map((u) => (
                  <tr key={`${u.school_id}-${u.code}`} className="border-b border-slate-100 last:border-0">
                    <td className="px-3 py-2.5">
                      <span className="font-medium text-slate-800">{u.school_name}</span>
                      <span className="block text-xs text-slate-500">
                        {u.plan_code ?? '-'} {u.status ? `/ ${u.status}` : ''}
                      </span>
                    </td>
                    <td className="px-3 py-2.5 font-mono text-xs text-slate-700">{u.code}</td>
                    <td className="px-3 py-2.5">
                      <StateChip state={u.state} />
                      {u.ends_on && u.state === 'active' && (
                        <span className="block text-xs text-slate-500">
                          to {fmtDate(u.ends_on)}
                        </span>
                      )}
                      {u.removed_reason && (
                        <span className="block text-xs text-slate-500">{u.removed_reason}</span>
                      )}
                    </td>
                    <td className="px-3 py-2.5 text-xs text-slate-600">
                      {fmtDateTime(u.redeemed_at)}
                    </td>
                    <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
                      {u.trial_days_added
                        ? `${u.trial_days_added} days`
                        : `${u.times_applied}x`}
                    </td>
                    <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">
                      {u.trial_days_added ? '-' : formatPkr(u.total_saved)}
                    </td>
                    <td className="px-3 py-2.5 text-right">
                      {u.state === 'active' && (
                        <button
                          onClick={() => {
                            setErr(null)
                            setTaking({ id: u.school_id, name: u.school_name })
                          }}
                          className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Take off
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {/* THE REASON IS REQUIRED, and the database requires it too. Taking a
          discount off a school changes what they will be charged, and "why is
          this school suddenly paying more" has to have an answer that is a row
          rather than somebody's memory. AskDialog rather than window.prompt:
          once a browser has been told to stop showing dialogs from a page,
          prompt() returns null for ever and the button silently does nothing. */}
      {taking && (
        <AskDialog
          title={`Take the discount off ${taking.name}`}
          intro="They will be charged the full price at their next renewal. The record of what they had stays."
          reason={{
            label: 'Why',
            hint: 'Recorded against the school and shown in this list.',
            required: true,
            minLength: 4,
            placeholder: 'Campaign ended; moved to an annual contract',
          }}
          confirmLabel="Take it off"
          tone="danger"
          busy={revoke.isPending}
          error={err}
          onCancel={() => setTaking(null)}
          onSubmit={({ reason }) => {
            revoke.mutate({ id: taking.id, reason },
              { onSuccess: () => setTaking(null) })
          }}
        />
      )}

      {editing && (
        <DiscountForm
          code={editing === 'new' ? null : editing}
          planCodes={(plans.data ?? []).map((p) => p.code)}
          onClose={() => setEditing(null)}
          onSaved={() => { setEditing(null); refresh() }}
        />
      )}
    </div>
  )
}

function StateChip({ state }: { state: 'active' | 'spent' | 'expired' | 'removed' }) {
  const tone = state === 'active' ? 'bg-money-100 text-money-800'
    : state === 'removed' ? 'bg-danger-100 text-danger-700'
    : 'bg-slate-100 text-slate-600'
  return (
    <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${tone}`}>{state}</span>
  )
}

/**
 * Create or edit a code.
 *
 * THE FORM CHANGES SHAPE WITH THE KIND, rather than showing eleven fields and
 * letting the database refuse nine combinations of them. A trial extension has
 * no duration to choose (it moves a date once, by definition) and is measured
 * in days rather than in rupees, so those controls are not rendered at all
 * instead of being rendered and rejected.
 */
function DiscountForm({
  code, planCodes, onClose, onSaved,
}: {
  code: DiscountCode | null
  planCodes: string[]
  onClose: () => void
  onSaved: () => void
}) {
  const [f, setF] = useState<SaveDiscountInput>(() => ({
    code: code?.code ?? '',
    description: code?.description ?? '',
    kind: code?.kind ?? 'percent',
    value: code?.value ?? 10,
    duration: code?.duration ?? 'once',
    durationMonths: code?.duration_months ?? null,
    durationUntil: code?.duration_until ?? null,
    redeemFrom: code?.redeem_from ?? null,
    redeemUntil: code?.redeem_until ?? null,
    maxRedemptions: code?.max_redemptions ?? null,
    planCodes: code?.plan_codes ?? null,
    minTermMonths: code?.min_term_months ?? null,
    active: code?.active ?? true,
  }))
  const [err, setErr] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  const save = useMutation({
    mutationFn: () => saveDiscount({
      ...f,
      // A trial extension moves a date once. The database refuses any other
      // duration for it; sending the right one from here means the operator
      // never sees that refusal.
      duration: f.kind === 'trial_days' ? 'once' : f.duration,
      code: f.code.trim().toUpperCase(),
    }),
    onSuccess: (r) => {
      if (r.note) { setNote(r.note); setTimeout(onSaved, 2500) } else onSaved()
    },
    onError: (e: Error) => setErr(e.message),
  })

  const set = <K extends keyof SaveDiscountInput>(k: K, v: SaveDiscountInput[K]) =>
    setF((p) => ({ ...p, [k]: v }))

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-pop">
        <h3 className="text-base font-semibold text-slate-900">
          {code ? `Edit ${code.code}` : 'New discount code'}
        </h3>

        <div className="mt-4 space-y-3">
          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className={LABEL}>Code</span>
              <input
                value={f.code}
                disabled={!!code}
                onChange={(e) => set('code', e.target.value.toUpperCase())}
                placeholder="SPRING20"
                className={`${FIELD} font-mono uppercase disabled:bg-slate-100`}
              />
            </label>
            <label className="block">
              <span className={LABEL}>On offer</span>
              <select
                value={f.active ? 'yes' : 'no'}
                onChange={(e) => set('active', e.target.value === 'yes')}
                className={FIELD}
              >
                <option value="yes">Yes, schools can use it</option>
                <option value="no">No, retired</option>
              </select>
            </label>
          </div>

          <label className="block">
            <span className={LABEL}>What it is for, in our own words</span>
            <input
              value={f.description}
              onChange={(e) => set('description', e.target.value)}
              placeholder="Spring campaign, first 50 schools"
              className={FIELD}
            />
          </label>

          <div className="grid gap-3 sm:grid-cols-2">
            <label className="block">
              <span className={LABEL}>Takes off</span>
              <select
                value={f.kind}
                onChange={(e) => set('kind', e.target.value as DiscountKind)}
                className={FIELD}
              >
                <option value="percent">A percentage</option>
                <option value="flat">A flat amount in rupees</option>
                <option value="trial_days">Extra free trial days</option>
              </select>
            </label>
            <label className="block">
              <span className={LABEL}>
                {f.kind === 'percent' ? 'Percent' : f.kind === 'flat' ? 'Rupees' : 'Days'}
              </span>
              <input
                type="number" min={1} step={f.kind === 'percent' ? 0.5 : 1}
                max={f.kind === 'percent' ? 100 : f.kind === 'trial_days' ? 365 : undefined}
                value={f.value}
                onChange={(e) => set('value', Number(e.target.value))}
                className={FIELD}
              />
            </label>
          </div>

          {f.kind !== 'trial_days' && (
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="block">
                <span className={LABEL}>For how long</span>
                <select
                  value={f.duration}
                  onChange={(e) => set('duration', e.target.value as DiscountDuration)}
                  className={FIELD}
                >
                  <option value="once">The next invoice only</option>
                  <option value="forever">Every invoice, for ever</option>
                  <option value="months">Every invoice, for some months</option>
                  <option value="until">Every invoice, up to a date</option>
                </select>
              </label>
              {f.duration === 'months' && (
                <label className="block">
                  <span className={LABEL}>Months</span>
                  <input type="number" min={1} max={120}
                    value={f.durationMonths ?? 12}
                    onChange={(e) => set('durationMonths', Number(e.target.value))}
                    className={FIELD} />
                </label>
              )}
              {f.duration === 'until' && (
                <label className="block">
                  <span className={LABEL}>Up to</span>
                  <input type="date" value={f.durationUntil ?? ''}
                    onChange={(e) => set('durationUntil', e.target.value || null)}
                    className={FIELD} />
                </label>
              )}
            </div>
          )}

          <fieldset className="rounded border border-slate-200 p-3">
            <legend className="px-1 text-xs font-medium text-slate-500">
              Who can use it, and when
            </legend>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="block">
                <span className={LABEL}>Usable from</span>
                <input type="date" value={f.redeemFrom ?? ''}
                  onChange={(e) => set('redeemFrom', e.target.value || null)}
                  className={FIELD} />
              </label>
              <label className="block">
                <span className={LABEL}>Usable until</span>
                <input type="date" value={f.redeemUntil ?? ''}
                  onChange={(e) => set('redeemUntil', e.target.value || null)}
                  className={FIELD} />
              </label>
              <label className="block">
                <span className={LABEL}>How many schools (blank for no limit)</span>
                <input type="number" min={1} value={f.maxRedemptions ?? ''}
                  onChange={(e) => set('maxRedemptions',
                    e.target.value === '' ? null : Number(e.target.value))}
                  className={FIELD} />
              </label>
              <label className="block">
                <span className={LABEL}>Shortest term it applies to</span>
                <select
                  value={f.minTermMonths ?? ''}
                  onChange={(e) => set('minTermMonths',
                    e.target.value === '' ? null : Number(e.target.value))}
                  className={FIELD}
                >
                  <option value="">Any term</option>
                  <option value="3">3 months or longer</option>
                  <option value="12">A year</option>
                </select>
              </label>
            </div>
            <div className="mt-3">
              <span className={LABEL}>Plans (none ticked means every plan)</span>
              <div className="mt-1 flex flex-wrap gap-2">
                {planCodes.map((p) => {
                  const on = (f.planCodes ?? []).includes(p)
                  return (
                    <label key={p}
                      className={`cursor-pointer rounded border px-2 py-1 text-xs font-medium ${
                        on ? 'border-brand-600 bg-brand-600 text-white'
                           : 'border-slate-300 bg-white text-slate-700'}`}>
                      <input type="checkbox" className="sr-only" checked={on}
                        onChange={() => {
                          const next = on
                            ? (f.planCodes ?? []).filter((x) => x !== p)
                            : [...(f.planCodes ?? []), p]
                          set('planCodes', next.length ? next : null)
                        }} />
                      {p}
                    </label>
                  )
                })}
              </div>
            </div>
          </fieldset>

          {note && (
            <p className="rounded border border-info-200 bg-info-50 px-3 py-2 text-sm text-info-800">
              {note}
            </p>
          )}
          {err && (
            <p className="rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
              {err}
            </p>
          )}
        </div>

        <div className="mt-5 flex justify-end gap-2">
          <button onClick={onClose}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50">
            Cancel
          </button>
          <button
            onClick={() => { setErr(null); save.mutate() }}
            disabled={save.isPending || !f.code.trim() || !f.description.trim()}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
          >
            {save.isPending ? 'Saving…' : code ? 'Save changes' : 'Create code'}
          </button>
        </div>
      </div>
    </div>
  )
}

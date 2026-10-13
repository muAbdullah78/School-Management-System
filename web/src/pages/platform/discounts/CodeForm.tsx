import { useId, useMemo, useState, type ReactNode } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  createDiscount, editDiscount, listDiscounts,
  type DiscountCode, type DiscountDuration, type DiscountKind, type PlatformSchool,
} from '@/lib/platform'
import { fmtDate } from '@/lib/format'
import { today } from '@/lib/dates'
import {
  BLANK_FORM, changedTerms, checkTerms, formFromCode, isStaleEdit, normCode, planNames,
  termsFromForm, type PricedPlan, type TermsForm,
} from './rules'
import { WorkedExample } from './WorkedExample'

export const FIELD =
  'w-full rounded border border-slate-300 bg-white px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 disabled:bg-slate-100'
const LABEL = 'block text-xs font-medium text-slate-600'
const HINT = 'mt-0.5 block text-xs text-slate-400'

/** Said wherever a locked code's terms are shown, in one wording. */
export const LOCKED_SENTENCE =
  'Schools already have this code. Retire it and make a new one to change what it gives.'

const STALE_SENTENCE = 'Somebody changed this code while you were editing it. Reload it.'

/** The dialog frame every discount form shares. */
export function Shell({ title, children, onClose, wide }: {
  title: string; children: ReactNode; onClose: () => void; wide?: boolean
}) {
  const id = useId()
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 sm:items-center"
      role="dialog" aria-modal="true" aria-labelledby={id}
      onKeyDown={(e) => { if (e.key === 'Escape') onClose() }}>
      <div className={`w-full ${wide ? 'max-w-2xl' : 'max-w-lg'} rounded-lg bg-white p-5 shadow-xl`}>
        <h3 id={id} className="text-base font-semibold text-slate-900">{title}</h3>
        {children}
      </div>
    </div>
  )
}

export function Problem({ children }: { children: ReactNode }) {
  return (
    <p role="alert" className="rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
      {children}
    </p>
  )
}

/**
 * A new code.
 *
 * SEPARATE FROM EDIT ON PURPOSE. The old form did both, and "New code" with a
 * name that already existed quietly rewrote that code under every school that
 * had it. Creating now refuses an existing name (the database says so), and
 * changing a code is the Edit form, which carries the version it was opened
 * from.
 */
export function NewCodeForm({ plans, schools, onClose, onCreated }: {
  plans: PricedPlan[]
  schools: PlatformSchool[]
  onClose: () => void
  onCreated: (made: { code: string; summary: string; private: boolean; schoolId: string | null }) => void
}) {
  const qc = useQueryClient()
  const [f, setF] = useState<TermsForm>(BLANK_FORM)
  const [err, setErr] = useState<string | null>(null)
  const order = useMemo(() => plans.map((p) => p.code), [plans])
  const terms = termsFromForm(f, order)

  const create = useMutation({
    mutationFn: () => createDiscount({ ...terms, code: normCode(f.code) || null }),
    onSuccess: (r) => {
      void qc.invalidateQueries({ queryKey: ['discounts'] })
      void qc.invalidateQueries({ queryKey: ['discountEvents'] })
      onCreated({
        code: r.code, summary: r.summary, private: terms.private ?? false,
        schoolId: terms.school_id ?? null,
      })
    },
    onError: (e: Error) => setErr(e.message),
  })

  const submit = () => {
    const bad = checkTerms({ ...terms, code: f.code }, { today: today() })
    if (bad) { setErr(bad); return }
    setErr(null)
    create.mutate()
  }

  return (
    <Shell title="New discount code" onClose={onClose} wide>
      <form className="mt-4 space-y-3" onSubmit={(e) => { e.preventDefault(); submit() }}>
        <NamesFields f={f} setF={setF} creating />
        <TermsFields f={f} setF={setF} plans={plans} />
        <WhoFields f={f} setF={setF} schools={schools} creating />
        <WindowFields f={f} setF={setF} />
        <WorkedExample terms={terms} code={normCode(f.code)} plans={plans} start={today()} />
        {err && <Problem>{err}</Problem>}
        <Buttons busy={create.isPending} onClose={onClose} label="Create code" />
      </form>
    </Shell>
  )
}

/**
 * Change a code.
 *
 * THE VERSION IT WAS OPENED FROM GOES WITH THE CHANGE. Two of us editing the
 * same code used to mean the second save silently undid the first; now the
 * database refuses a change made from an old copy, and this form says so and
 * offers to reload. The copy is pinned when the form opens and replaced only
 * by that reload: a background refetch swapping it underneath would send the
 * new version with the old edits and defeat the check.
 *
 * ONCE A SCHOOL HAS IT, WHAT IT GIVES IS LOCKED. Those fields are shown, not
 * offered, with the reason; the name, our description, the dates it can be
 * taken up, the number of schools and the on-offer switch stay editable.
 */
export function EditCodeForm({ code, plans, schools, onClose, onSaved }: {
  code: DiscountCode
  plans: PricedPlan[]
  schools: PlatformSchool[]
  onClose: () => void
  onSaved: (note: string | null) => void
}) {
  const qc = useQueryClient()
  const [base, setBase] = useState(code)
  const [f, setF] = useState<TermsForm>(() => formFromCode(code))
  const [err, setErr] = useState<string | null>(null)
  const [stale, setStale] = useState(false)
  const order = useMemo(() => plans.map((p) => p.code), [plans])
  const locked = base.terms_locked
  const before = useMemo(() => termsFromForm(formFromCode(base), order), [base, order])
  const after = termsFromForm(f, order)
  const changes = changedTerms(before, after, locked)
  const nothing = Object.keys(changes).length === 0

  const save = useMutation({
    mutationFn: () => editDiscount(base.code, changes, base.updated_at),
    onSuccess: (r) => {
      void qc.invalidateQueries({ queryKey: ['discounts'] })
      void qc.invalidateQueries({ queryKey: ['discountEvents'] })
      onSaved(r?.note ?? null)
    },
    onError: (e: Error) => {
      if (isStaleEdit(e)) { setStale(true); setErr(null) } else setErr(e.message)
    },
  })

  const reload = useMutation({
    mutationFn: () => qc.fetchQuery({ queryKey: ['discounts'], queryFn: listDiscounts, staleTime: 0 }),
    onSuccess: (rows) => {
      const fresh = rows.find((c) => c.code === base.code)
      setStale(false)
      if (!fresh) { setErr(`There is no code called ${base.code} any more.`); return }
      setBase(fresh); setF(formFromCode(fresh)); setErr(null)
    },
    onError: (e: Error) => setErr(e.message),
  })

  const submit = () => {
    if (nothing) return
    const bad = checkTerms(after, {
      today: today(), before, seatsTaken: base.seats_taken, codeName: base.code,
    })
    if (bad) { setErr(bad); return }
    setErr(null)
    save.mutate()
  }

  return (
    <Shell title={`Edit ${base.code}`} onClose={onClose} wide>
      <form className="mt-4 space-y-3" onSubmit={(e) => { e.preventDefault(); submit() }}>
        <NamesFields f={f} setF={setF} />
        {locked ? (
          <LockedTerms code={base} plans={plans} />
        ) : (
          <>
            <TermsFields f={f} setF={setF} plans={plans} />
            <WhoFields f={f} setF={setF} schools={schools} />
          </>
        )}
        <WindowFields f={f} setF={setF} seatsTaken={base.seats_taken} editing />
        {!locked && (
          <WorkedExample terms={after} code={base.code} plans={plans} start={today()} />
        )}
        {stale && (
          <div role="alert" className="flex flex-wrap items-center justify-between gap-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
            <span>{STALE_SENTENCE}</span>
            <button type="button" onClick={() => reload.mutate()} disabled={reload.isPending}
              className="rounded border border-due-300 bg-white px-2 py-1 text-xs font-medium text-due-800 hover:bg-due-100 disabled:opacity-60">
              {reload.isPending ? 'Reloading…' : 'Reload it'}
            </button>
          </div>
        )}
        {err && <Problem>{err}</Problem>}
        <Buttons busy={save.isPending} onClose={onClose}
          label={nothing ? 'Nothing changed' : 'Save changes'} disabled={nothing || stale} />
      </form>
    </Shell>
  )
}

/** What a locked code gives, shown and not offered. */
function LockedTerms({ code, plans }: { code: DiscountCode; plans: PricedPlan[] }) {
  return (
    <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm">
      <p className="text-xs font-medium text-slate-600">What it gives: locked</p>
      <dl className="mt-1 grid gap-x-3 gap-y-0.5 text-sm sm:grid-cols-[max-content_1fr]">
        <dt className="text-slate-500">Gives</dt>
        <dd className="text-slate-800">{code.summary}</dd>
        {code.kind !== 'trial_days' && <>
          <dt className="text-slate-500">Plans</dt>
          <dd className="text-slate-800">{planNames(code.plan_codes, plans)}</dd>
          <dt className="text-slate-500">Shortest term</dt>
          <dd className="text-slate-800">
            {code.min_term_months ? `${code.min_term_months} months` : 'Any term'}
          </dd>
        </>}
        <dt className="text-slate-500">Who can have it</dt>
        <dd className="text-slate-800">
          {code.private ? `Only ${code.school_name ?? 'a school no longer listed'}` : 'Any school'}
        </dd>
      </dl>
      <p className="mt-2 text-xs text-slate-600">{LOCKED_SENTENCE}</p>
    </div>
  )
}

type FieldsProps = { f: TermsForm; setF: (u: (p: TermsForm) => TermsForm) => void }

function NamesFields({ f, setF, creating }: FieldsProps & { creating?: boolean }) {
  return (
    <div className="grid gap-3 sm:grid-cols-2">
      {creating && (
        <label className="block">
          <span className={LABEL}>Code</span>
          <input value={f.code} autoFocus
            onChange={(e) => setF((p) => ({ ...p, code: normCode(e.target.value) }))}
            placeholder="SPRING26" maxLength={32} autoComplete="off" spellCheck={false}
            className={`${FIELD} font-mono uppercase`} />
          <span className={HINT}>
            {f.private
              ? 'Leave it empty and we make up a 10-character one.'
              : '6 to 32 letters, digits, dashes or underscores. Short codes are guessed.'}
          </span>
        </label>
      )}
      <label className={`block ${creating ? '' : 'sm:col-span-2'}`}>
        <span className={LABEL}>Label: what schools see</span>
        <input value={f.label} maxLength={80} autoFocus={!creating}
          onChange={(e) => setF((p) => ({ ...p, label: e.target.value }))}
          placeholder="Spring offer" className={FIELD} />
        <span className={HINT}>The name of the offer on their invoice and screens. Up to 80 characters.</span>
      </label>
      <label className="block sm:col-span-2">
        <span className={LABEL}>
          Our description <span className="font-normal text-slate-400">(only we see this)</span>
        </span>
        <input value={f.description}
          onChange={(e) => setF((p) => ({ ...p, description: e.target.value }))}
          placeholder="Spring campaign for schools in Lahore" className={FIELD} />
      </label>
    </div>
  )
}

/** Kind, amount, duration, plans and term: what the code gives. */
function TermsFields({ f, setF, plans }: FieldsProps & { plans: PricedPlan[] }) {
  const trial = f.kind === 'trial_days'
  // A new kind needs a new amount: 20 percent is nothing like Rs 20 off, and
  // trial days are added once with no duration, plan or term to choose.
  const setKind = (kind: DiscountKind) => setF((p) => kind === p.kind ? p : ({
    ...p, kind, value: '',
    duration: kind === 'trial_days' ? 'once' : p.duration === 'once' ? 'months' : p.duration,
    durationMonths: p.durationMonths || '3',
  }))
  const onSale = plans.filter((p) => p.active)

  return (
    <fieldset className="rounded border border-slate-200 p-3">
      <legend className="px-1 text-xs font-medium text-slate-500">What it gives</legend>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className={LABEL}>Kind</span>
          <select value={f.kind} onChange={(e) => setKind(e.target.value as DiscountKind)} className={FIELD}>
            <option value="percent">Percent off</option>
            <option value="flat">Rupees off each month</option>
            <option value="trial_days">Extra trial days</option>
          </select>
        </label>
        <label className="block">
          <span className={LABEL}>
            {f.kind === 'percent' ? 'Percent' : f.kind === 'flat' ? 'Rupees each month' : 'Days'}
          </span>
          <input type="number" inputMode="decimal" min={1}
            step={f.kind === 'percent' ? 0.5 : 1}
            max={f.kind === 'percent' ? 100 : f.kind === 'trial_days' ? 30 : 50000}
            value={f.value} onChange={(e) => setF((p) => ({ ...p, value: e.target.value }))}
            className={FIELD} />
          {trial && <span className={HINT}>1 to 30 days, once per school.</span>}
        </label>
        {!trial && (
          <label className="block">
            <span className={LABEL}>For how long</span>
            <select value={f.duration}
              onChange={(e) => setF((p) => ({ ...p, duration: e.target.value as DiscountDuration }))}
              className={FIELD}>
              <option value="months">For a number of months</option>
              <option value="until">Until a date</option>
              <option value="forever">For as long as they subscribe</option>
            </select>
          </label>
        )}
      </div>

      {!trial && f.duration !== 'forever' && (
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          {f.duration === 'months' && (
            <label className="block">
              <span className={LABEL}>Billed months</span>
              <input type="number" min={1} max={36} step={1} value={f.durationMonths}
                onChange={(e) => setF((p) => ({ ...p, durationMonths: e.target.value }))}
                className={FIELD} />
              <span className={HINT}>1 to 36. A yearly invoice uses 12 of them at once.</span>
            </label>
          )}
          {f.duration === 'until' && (
            <label className="block">
              <span className={LABEL}>Every billed month that starts by</span>
              <input type="date" value={f.durationUntil}
                onChange={(e) => setF((p) => ({ ...p, durationUntil: e.target.value }))}
                className={FIELD} />
            </label>
          )}
        </div>
      )}

      {!trial && (
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <fieldset>
            <legend className={LABEL}>Plans it is for</legend>
            <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1">
              {onSale.map((p) => (
                <label key={p.code} className="inline-flex items-center gap-1.5 text-sm text-slate-700">
                  <input type="checkbox" checked={f.planCodes.includes(p.code)}
                    onChange={(e) => setF((prev) => ({
                      ...prev,
                      planCodes: e.target.checked
                        ? [...prev.planCodes, p.code]
                        : prev.planCodes.filter((x) => x !== p.code),
                    }))}
                    className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500" />
                  {p.name}
                </label>
              ))}
            </div>
            <span className={HINT}>None ticked means every plan.</span>
          </fieldset>
          <label className="block">
            <span className={LABEL}>Shortest term it applies to</span>
            <select value={f.minTermMonths}
              onChange={(e) => setF((p) => ({ ...p, minTermMonths: e.target.value as TermsForm['minTermMonths'] }))}
              className={FIELD}>
              <option value="">Any term</option>
              <option value="3">3 months or longer</option>
              <option value="12">A year</option>
            </select>
            <span className={HINT}>Checked on every invoice: a shorter one skips the code and says why.</span>
          </label>
        </div>
      )}
    </fieldset>
  )
}

/** A code for everybody, or private to one school. */
function WhoFields({ f, setF, schools, creating }: FieldsProps & {
  schools: PlatformSchool[]; creating?: boolean
}) {
  const list = useMemo(() => schools.filter((s) => !s.archived)
    .sort((a, b) => a.school_name.localeCompare(b.school_name)), [schools])
  return (
    <div className="space-y-2">
      <label className="inline-flex items-center gap-2 text-sm text-slate-700">
        <input type="checkbox" checked={f.private}
          onChange={(e) => setF((p) => ({ ...p, private: e.target.checked }))}
          className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500" />
        Private: made for one school
      </label>
      {f.private && (
        <label className="block">
          <span className={LABEL}>Which school</span>
          <select value={f.schoolId}
            onChange={(e) => setF((p) => ({ ...p, schoolId: e.target.value }))} className={FIELD}>
            <option value="">Choose the school</option>
            {list.map((s) => (
              <option key={s.school_id} value={s.school_id}>
                {s.school_name}{s.city ? `, ${s.city}` : ''}
              </option>
            ))}
          </select>
          <span className={HINT}>
            Only this school can have it, and only when we give it to them. It has one place.
            {creating && ' Give it to them from the list once it is made.'}
          </span>
        </label>
      )}
    </div>
  )
}

/** When it can be taken up, by how many schools, and whether it is on offer. */
function WindowFields({ f, setF, seatsTaken, editing }: FieldsProps & {
  seatsTaken?: number; editing?: boolean
}) {
  return (
    <fieldset className="rounded border border-slate-200 p-3">
      <legend className="px-1 text-xs font-medium text-slate-500">When, and how many schools</legend>
      <div className="grid gap-3 sm:grid-cols-3">
        <label className="block">
          <span className={LABEL}>Can be taken up from</span>
          <input type="date" value={f.redeemFrom}
            onChange={(e) => setF((p) => ({ ...p, redeemFrom: e.target.value }))} className={FIELD} />
          <span className={HINT}>Empty: from today.</span>
        </label>
        <label className="block">
          <span className={LABEL}>Can be taken up until</span>
          <input type="date" value={f.redeemUntil}
            onChange={(e) => setF((p) => ({ ...p, redeemUntil: e.target.value }))} className={FIELD} />
          <span className={HINT}>Empty: no end.</span>
        </label>
        {f.private ? (
          <div>
            <span className={LABEL}>Most schools</span>
            <p className="py-1.5 text-sm text-slate-700">One: it is private</p>
          </div>
        ) : (
          <label className="block">
            <span className={LABEL}>Most schools</span>
            <input type="number" min={Math.max(1, seatsTaken ?? 0)} step={1} value={f.maxRedemptions}
              onChange={(e) => setF((p) => ({ ...p, maxRedemptions: e.target.value }))}
              placeholder="No limit" className={FIELD} />
            <span className={HINT}>
              Empty: no limit.
              {editing && !!seatsTaken && ` ${seatsTaken} place(s) taken now; it cannot go below that.`}
            </span>
          </label>
        )}
      </div>
      {editing && (
        <label className="mt-3 block sm:w-1/2">
          <span className={LABEL}>On offer</span>
          <select value={f.active ? 'yes' : 'no'}
            onChange={(e) => setF((p) => ({ ...p, active: e.target.value === 'yes' }))} className={FIELD}>
            <option value="yes">Yes, schools can take it up</option>
            <option value="no">No, retired</option>
          </select>
          <span className={HINT}>
            Schools that already have it keep it either way. Retire from the list to give a reason.
          </span>
        </label>
      )}
      {f.redeemUntil && f.redeemUntil < today() && (
        <p className="mt-2 text-xs text-slate-500">
          It could be taken up until {fmtDate(f.redeemUntil)}, which has passed.
        </p>
      )}
    </fieldset>
  )
}

function Buttons({ busy, onClose, label, disabled }: {
  busy: boolean; onClose: () => void; label: string; disabled?: boolean
}) {
  return (
    <div className="flex justify-end gap-2 pt-1">
      <button type="button" onClick={onClose}
        className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-brand-500">
        Cancel
      </button>
      <button type="submit" disabled={busy || disabled}
        className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-60">
        {busy ? 'Saving…' : label}
      </button>
    </div>
  )
}

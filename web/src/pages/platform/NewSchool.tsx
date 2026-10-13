import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { createSchool, createSchoolOwner } from '@/lib/platform'
import { listSignupPlans, planForStudents, TERM_LABEL } from '@/lib/plans'
import type { Term } from '@/lib/subscription'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'
import { money } from './status'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Add a school from the console.
 *
 * The first fifty customers do not sign themselves up. They are schools somebody
 * met, demonstrated to, and typed in, and until now the only way to create one
 * was the public signup form, which means asking a principal to do it on the
 * phone while you wait.
 *
 * THE ONE THING THIS SCREEN MUST NOT DO IS LOOK FINISHED. Creating a school row
 * does not create a login: nobody can sign in, and in the console the result is
 * indistinguishable from an ordinary trialing customer. Minting an auth user
 * needs the service_role key, which must never reach a browser, so the owner
 * login goes through the create-school-owner Edge Function, and the panel below
 * stays amber until that is done.
 *
 * The first version of this offered the /signup link instead, which was wrong:
 * /signup calls `signup-school`, which creates a NEW school. A principal
 * following that link would have ended up with a second, empty school while the
 * one set up here stayed unreachable.
 *
 * THE NUMBER OF PUPILS DECIDES THE PLAN (0155), here exactly as on the public
 * signup: up to 280 Starter, up to 1,000 Growth, more than that Enterprise.
 * There is no plan picker, because a plan chosen by hand against a roll is how
 * a school ends up over its limit on day one. The plan and its price are read
 * from the database and shown before anything is saved. An Enterprise school
 * can be given its agreed monthly price here, with how it was agreed; without
 * one it locks the day after its trial until we set it.
 */
export function NewSchoolDialog({ onClose, onCreated }: {
  onClose: () => void
  onCreated: (schoolId: string, name: string) => void
}) {
  const qc = useQueryClient()
  const plans = useQuery({ queryKey: ['signupPlans'], queryFn: listSignupPlans, staleTime: 5 * 60_000 })
  const [name, setName] = useState('')
  const [city, setCity] = useState('')
  const [contactName, setContactName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [pupils, setPupils] = useState('')
  const [term, setTerm] = useState<Term>(1)
  const [trial, setTrial] = useState('14')
  const [monthly, setMonthly] = useState('')
  const [agreedHow, setAgreedHow] = useState('')
  const [notes, setNotes] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [made, setMade] = useState<Awaited<ReturnType<typeof createSchool>> | null>(null)

  const n = Number(pupils)
  const pupilsOk = Number.isInteger(n) && n >= 1 && n <= 100_000
  // A hint mirroring the database's rule; the database decides when it saves.
  const plan = pupilsOk ? planForStudents(plans.data ?? [], n) : null
  const enterprise = plan?.by_arrangement === true
  const m = money(monthly)
  const priced = enterprise && monthly.trim() !== ''
  const days = Number(trial)
  const problem = name.trim().length < 2 ? 'Type the school name.'
    : !pupilsOk ? 'Type the number of pupils on their roll, between 1 and 100,000. The plan follows from it.'
    : !(Number.isInteger(days) && days >= 0 && days <= 180) ? 'A trial is between 0 and 180 days.'
    : priced && !(Number.isInteger(m) && m > 0) ? 'The monthly price is a whole number of rupees above zero, or left empty.'
    : priced && agreedHow.trim().length < 8 ? 'Say how the price was agreed: who, when, for how many pupils.'
    : null

  const save = useMutation({
    mutationFn: () => createSchool({
      name, city: city.trim() || null,
      contactName: contactName.trim() || null,
      contactPhone: phone.trim() || null,
      contactEmail: email.trim() || null,
      // No plan code: the number of pupils picks it, on the server.
      students: n, termMonths: term, trialDays: days,
      notes: notes.trim() || null,
      agreedMonthly: priced ? m : null,
      agreedReason: priced ? agreedHow.trim() : null,
    }),
    onSuccess: (r) => {
      setErr(null); setMade(r)
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (made) {
    const on = plans.data?.find((p) => p.code === made.plan_code)
    return (
      <Shell title={`${made.name} added`} onClose={onClose}>
        <p className="text-sm text-slate-700">
          On <span className="font-medium">{on?.name ?? made.plan_code}</span>, free until{' '}
          <span className="font-medium">{fmtDate(made.trial_ends_on)}</span>{' '}
          ({made.trial_days} days of access).
          {on?.by_arrangement && !priced && (
            <> No price is agreed yet: set it on their page before the trial ends, or they
              lock the next day with no grace.</>
          )}
        </p>
        <OwnerStep schoolId={made.school_id} stillNeeded={made.still_needed}
          suggestedEmail={email.trim().toLowerCase()}
          suggestedName={contactName.trim()}
          onDone={() => onCreated(made.school_id, made.name)} />
      </Shell>
    )
  }

  return (
    <Shell title="Add a school" onClose={onClose}>
      {err && <p className="rounded bg-danger-50 px-3 py-2 text-sm text-danger-700">{err}</p>}

      <div className="mt-1 space-y-3">
        <label className="block">
          <span className="text-xs font-medium text-slate-600">
            School name: as it should appear on their invoice
          </span>
          <input autoFocus className={FIELD} value={name}
            onChange={(e) => setName(e.target.value)} />
        </label>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">City</span>
            <input className={FIELD} value={city} onChange={(e) => setCity(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Who you spoke to</span>
            <input className={FIELD} value={contactName}
              onChange={(e) => setContactName(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Phone</span>
            <input className={FIELD} value={phone} onChange={(e) => setPhone(e.target.value)}
              placeholder="0300-1234567" />
            <span className="mt-0.5 block text-xs text-slate-400">
              Renewal reminders go here on WhatsApp. Without it there is nothing to
              send them.
            </span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Email</span>
            <input className={FIELD} value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
        </div>
        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-xs font-medium text-slate-600">
              Pupils on their roll<span className="text-danger-600"> *</span>
            </span>
            <input type="number" min={1} max={100000} step={1} className={FIELD} value={pupils}
              onChange={(e) => setPupils(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              The plan follows from this number.
            </span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Free trial (days of access)</span>
            <input type="number" min={0} max={180} className={FIELD} value={trial}
              onChange={(e) => setTrial(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              Fourteen means today and the next thirteen days.
            </span>
          </label>
        </div>

        {/* THE PLAN AND ITS PRICE, BEFORE ANYTHING IS SAVED. Read from the
            price list in the database, never typed here. */}
        {plans.error && (
          <p className="text-xs text-slate-500">
            The price list could not be read. The plan still follows from the number of
            pupils when you save.
          </p>
        )}
        {plan && (
          <div className="rounded border border-slate-200 bg-slate-50 p-3 text-sm">
            <div>
              <span className="font-medium text-slate-800">{plan.name}</span>
              <span className="text-slate-500">
                {' · '}{plan.student_limit !== null
                  ? `up to ${plan.student_limit.toLocaleString()} pupils`
                  : 'no pupil limit'}
              </span>
            </div>
            {!enterprise && plan.terms.length > 0 && (
              <fieldset className="mt-2">
                <legend className="text-xs font-medium text-slate-600">How often they pay</legend>
                <div className="mt-1 grid gap-1.5 sm:grid-cols-3">
                  {plan.terms.map((t) => (
                    <label key={t.months}
                      className={`flex cursor-pointer items-start gap-2 rounded border px-2 py-1.5 text-xs focus-within:ring-2 focus-within:ring-brand-500 ${
                        term === t.months ? 'border-brand-500 bg-white' : 'border-slate-200 bg-white hover:bg-slate-50'}`}>
                      <input type="radio" name="term" className="mt-0.5" checked={term === t.months}
                        onChange={() => setTerm(t.months)} />
                      <span>
                        <span className="block font-medium text-slate-800">
                          {TERM_LABEL[t.months] ?? `${t.months} months`}
                        </span>
                        <span className="block tabular-nums text-slate-700">{formatPkr(t.amount)}</span>
                        {t.saving > 0 && (
                          <span className="block text-money-700">saves {formatPkr(t.saving)}</span>
                        )}
                      </span>
                    </label>
                  ))}
                </div>
              </fieldset>
            )}
            {enterprise && (
              <div className="mt-2 space-y-2">
                <p className="text-xs text-slate-600">
                  {plan.how_priced ?? 'Priced with each school.'} Leave the price empty to agree
                  it later: until it is set they cannot be invoiced, and they lock the day after
                  their trial ends, with no grace.
                </p>
                <div className="grid gap-3 sm:grid-cols-2">
                  <label className="block">
                    <span className="text-xs font-medium text-slate-600">Agreed price a month</span>
                    <input className={FIELD} value={monthly} inputMode="numeric"
                      placeholder="optional, whole rupees"
                      onChange={(e) => setMonthly(e.target.value)} />
                  </label>
                  <label className="block">
                    <span className="text-xs font-medium text-slate-600">
                      How it was agreed{priced && <span className="text-danger-600"> *</span>}
                    </span>
                    <input className={FIELD} value={agreedHow} disabled={!priced}
                      placeholder={priced ? 'who, when, for how many pupils' : 'with a price'}
                      onChange={(e) => setAgreedHow(e.target.value)} />
                  </label>
                </div>
                <fieldset>
                  <legend className="text-xs font-medium text-slate-600">How often they pay</legend>
                  <div className="mt-1 flex flex-wrap gap-3 text-xs">
                    {([1, 3, 12] as Term[]).map((t) => (
                      <label key={t} className="flex items-center gap-1.5">
                        <input type="radio" name="term" checked={term === t} onChange={() => setTerm(t)} />
                        {TERM_LABEL[t]}
                      </label>
                    ))}
                  </div>
                </fieldset>
              </div>
            )}
          </div>
        )}
        <label className="block">
          <span className="text-xs font-medium text-slate-600">
            Notes, where you met them, who introduced you
          </span>
          <input className={FIELD} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
      </div>

      {problem && name.trim() !== '' && (
        <p className="mt-3 rounded border border-due-200 bg-due-50 px-3 py-2 text-xs text-due-900">
          {problem}
        </p>
      )}

      <div className="mt-4 flex gap-2">
        <button onClick={() => save.mutate()} disabled={save.isPending || problem !== null}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {save.isPending ? 'Adding…' : 'Add the school'}
        </button>
        <button onClick={onClose}
          className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
          Cancel
        </button>
      </div>
    </Shell>
  )
}

function Shell({ title, onClose, children }: {
  title: string; onClose: () => void; children: React.ReactNode
}) {
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <h2 className="text-base font-semibold text-slate-800">{title}</h2>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        <div className="mt-3">{children}</div>
      </div>
    </div>
  )
}

/**
 * The second half of adding a school, and the half that is easy to skip.
 *
 * A school row with no login is invisible from the school's side and looks like
 * an ordinary trialing customer from ours. The panel is amber until it is done,
 * because "added the school" is not the same as "they can use it".
 *
 * The password is typed here and handed over verbally, and the copy says to have
 * it changed, which is the difference between a temporary password and a shared
 * one. There is no invite-by-email path because email delivery is not something
 * this deployment can assume, and an invite that silently never arrives is worse
 * than a password read out on the phone.
 */
function OwnerStep({ schoolId, stillNeeded, suggestedEmail, suggestedName, onDone }: {
  schoolId: string
  stillNeeded: string
  suggestedEmail: string
  suggestedName: string
  onDone: () => void
}) {
  const [email, setEmail] = useState(suggestedEmail)
  const [fullName, setFullName] = useState(suggestedName)
  const [password, setPassword] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState<{ email: string; next: string } | null>(null)

  const make = useMutation({
    mutationFn: () => createSchoolOwner({ schoolId, email, password, fullName }),
    onSuccess: (r) => { setErr(null); setDone({ email: r.email, next: r.next }) },
    onError: (e) => setErr((e as Error).message),
  })

  if (done) {
    return (
      <>
        <div className="mt-3 rounded border border-money-200 bg-money-50 p-3 text-sm text-money-900">
          <div className="font-semibold">They can sign in now.</div>
          <p className="mt-1">{done.next}</p>
          <div className="mt-2 rounded bg-white px-2 py-1 font-mono text-xs text-slate-700">
            {done.email}
          </div>
        </div>
        <button onClick={onDone}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Open the school
        </button>
      </>
    )
  }

  return (
    <>
      <div className="mt-3 rounded border border-due-300 bg-due-50 p-3">
        <div className="text-sm font-semibold text-due-900">{stillNeeded}</div>
        {err && <p className="mt-2 rounded bg-danger-50 px-2 py-1 text-sm text-danger-700">{err}</p>}
        <div className="mt-2 space-y-2">
          <label className="block">
            <span className="text-xs font-medium text-slate-700">
              The principal or owner&rsquo;s email
            </span>
            <input className={FIELD} value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-700">Their name</span>
            <input className={FIELD} value={fullName}
              onChange={(e) => setFullName(e.target.value)} />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-700">
              A password to give them
            </span>
            <input className={FIELD} value={password} autoComplete="off"
              onChange={(e) => setPassword(e.target.value)}
              placeholder="at least 8 characters" />
            <span className="mt-0.5 block text-xs text-due-800">
              Read it out to them and tell them to change it from their own profile.
              You should not be the person who knows their password a month from now.
            </span>
          </label>
        </div>
        <button onClick={() => make.mutate()}
          disabled={make.isPending || password.length < 8 || !email.includes('@')}
          className="mt-3 rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {make.isPending ? 'Creating…' : 'Create their login'}
        </button>
      </div>

      {/* Deliberately available, and deliberately second. A school that would
          rather set its own password can, and then the operator never knows it,
          but it means abandoning the school row just created, so it says so. */}
      <button onClick={onDone}
        className="mt-3 w-full rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
        Skip for now: I will sort the login out later
      </button>
    </>
  )
}

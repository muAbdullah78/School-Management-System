import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { createSchool, createSchoolOwner, listPlans } from '@/lib/platform'
import { fmtDate } from '@/lib/format'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * Add a school from the console.
 *
 * The first fifty customers do not sign themselves up. They are schools somebody
 * met, demonstrated to, and typed in — and until now the only way to create one
 * was the public signup form, which means asking a principal to do it on the
 * phone while you wait.
 *
 * THE ONE THING THIS SCREEN MUST NOT DO IS LOOK FINISHED. Creating a school row
 * does not create a login: nobody can sign in, and in the console the result is
 * indistinguishable from an ordinary trialing customer. Minting an auth user
 * needs the service_role key, which must never reach a browser, so the owner
 * login goes through the create-school-owner Edge Function — and the panel below
 * stays amber until that is done.
 *
 * The first version of this offered the /signup link instead, which was wrong:
 * /signup calls `signup-school`, which creates a NEW school. A principal
 * following that link would have ended up with a second, empty school while the
 * one set up here stayed unreachable.
 */
export function NewSchoolDialog({ onClose, onCreated }: {
  onClose: () => void
  onCreated: (schoolId: string, name: string) => void
}) {
  const qc = useQueryClient()
  const plans = useQuery({ queryKey: ['plans'], queryFn: listPlans })
  const [name, setName] = useState('')
  const [city, setCity] = useState('')
  const [contactName, setContactName] = useState('')
  const [phone, setPhone] = useState('')
  const [email, setEmail] = useState('')
  const [plan, setPlan] = useState('starter')
  const [trial, setTrial] = useState('14')
  const [notes, setNotes] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [made, setMade] = useState<Awaited<ReturnType<typeof createSchool>> | null>(null)

  const save = useMutation({
    mutationFn: () => createSchool({
      name, city: city.trim() || null,
      contactName: contactName.trim() || null,
      contactPhone: phone.trim() || null,
      contactEmail: email.trim() || null,
      planCode: plan, trialDays: Number(trial) || 0,
      notes: notes.trim() || null,
    }),
    onSuccess: (r) => {
      setErr(null); setMade(r)
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (made) {
    return (
      <Shell title={`${made.name} added`} onClose={onClose}>
        <p className="text-sm text-slate-700">
          On <span className="font-medium">{made.plan_code}</span>, free until{' '}
          <span className="font-medium">{fmtDate(made.trial_ends_on)}</span>{' '}
          ({made.trial_days} days).
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
      {err && <p className="rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

      <div className="mt-1 space-y-3">
        <label className="block">
          <span className="text-xs font-medium text-slate-600">
            School name — as it should appear on their invoice
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
            <span className="text-xs font-medium text-slate-600">Plan</span>
            <select className={FIELD} value={plan} onChange={(e) => setPlan(e.target.value)}>
              {(plans.data ?? []).filter((p) => p.active).map((p) => (
                <option key={p.code} value={p.code}>{p.name}</option>
              ))}
            </select>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Free trial (days)</span>
            <input type="number" min={0} max={180} className={FIELD} value={trial}
              onChange={(e) => setTrial(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              Long enough to get their pupils in and take a fee. Two weeks is rarely
              enough for a school in term time.
            </span>
          </label>
        </div>
        <label className="block">
          <span className="text-xs font-medium text-slate-600">
            Notes — where you met them, who introduced you
          </span>
          <input className={FIELD} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
      </div>

      <div className="mt-4 flex gap-2">
        <button onClick={() => save.mutate()} disabled={save.isPending || name.trim().length < 2}
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
 * it changed — which is the difference between a temporary password and a shared
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
        <div className="mt-3 rounded border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900">
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
      <div className="mt-3 rounded border border-amber-300 bg-amber-50 p-3">
        <div className="text-sm font-semibold text-amber-900">{stillNeeded}</div>
        {err && <p className="mt-2 rounded bg-red-50 px-2 py-1 text-sm text-red-700">{err}</p>}
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
            <span className="mt-0.5 block text-xs text-amber-800">
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
          rather set its own password can, and then the operator never knows it —
          but it means abandoning the school row just created, so it says so. */}
      <button onClick={onDone}
        className="mt-3 w-full rounded border border-slate-300 px-3 py-2 text-sm text-slate-600 hover:bg-slate-50">
        Skip for now — I will sort the login out later
      </button>
    </>
  )
}

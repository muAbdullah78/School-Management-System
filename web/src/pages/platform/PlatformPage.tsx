import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import {
  activateSubscription, actionNeeded, amPlatformAdmin, extendTrial, listPlans,
  listPlatformSchools, platformLedger, platformRevenue, platformSchemaState,
  recordPlatformPayment, refreshAllCounts, sortByAction,
  type PlatformSchool, type SchemaState,
} from '@/lib/platform'
import { formatPkr } from '@/lib/licence'

const STATUS_STYLE: Record<PlatformSchool['status'], string> = {
  trialing: 'bg-sky-100 text-sky-800',
  active: 'bg-emerald-100 text-emerald-800',
  grace: 'bg-amber-100 text-amber-800',
  locked: 'bg-red-100 text-red-800',
  cancelled: 'bg-slate-200 text-slate-700',
}

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm'

function monthStart(): string {
  const d = new Date()
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`
}
function today(): string {
  return new Date().toISOString().slice(0, 10)
}

/**
 * The product owner's console: every school, what they owe, and what needs
 * doing today.
 *
 * Ordered by what needs action rather than alphabetically — the whole point is
 * to answer "who do I call this morning?" without reading the list.
 */
export function PlatformPage() {
  const { signOut, session } = useAuth()
  const qc = useQueryClient()
  const [msg, setMsg] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [from, setFrom] = useState(monthStart())
  const [to, setTo] = useState(today())
  const [paying, setPaying] = useState<PlatformSchool | null>(null)
  const [ledgerFor, setLedgerFor] = useState<PlatformSchool | null>(null)

  const isAdmin = useQuery({ queryKey: ['amPlatformAdmin', session?.user?.id], queryFn: amPlatformAdmin })
  const schools = useQuery({
    queryKey: ['platformSchools'], queryFn: listPlatformSchools, enabled: isAdmin.data === true,
  })
  const plans = useQuery({ queryKey: ['plans'], queryFn: listPlans, enabled: isAdmin.data === true })
  const revenue = useQuery({
    queryKey: ['platformRevenue', from, to],
    queryFn: () => platformRevenue(from, to),
    enabled: isAdmin.data === true,
  })
  const schema = useQuery({
    queryKey: ['platformSchemaState'], queryFn: platformSchemaState, enabled: isAdmin.data === true,
  })

  const rows = useMemo(() => sortByAction(schools.data ?? []), [schools.data])

  const act = useMutation({
    mutationFn: async (fn: () => Promise<unknown>) => fn(),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
      void qc.invalidateQueries({ queryKey: ['platformLedger'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  function run(label: string, fn: () => Promise<unknown>) {
    setErr(null); setMsg(null)
    act.mutate(fn, { onSuccess: () => setMsg(label) })
  }

  if (isAdmin.isLoading) return <div className="p-8 text-slate-500">Loading…</div>

  if (isAdmin.data !== true) {
    return (
      <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
        <div className="w-full max-w-sm rounded-lg bg-white p-6 text-center shadow">
          <h1 className="text-lg font-semibold text-slate-800">Not available</h1>
          <p className="mt-2 text-sm text-slate-600">This area is for the system operator.</p>
          <button onClick={() => void signOut()} className="mt-4 text-sm text-brand-700 hover:underline">
            Sign out
          </button>
        </div>
      </div>
    )
  }

  const counts = {
    total: rows.length,
    paying: rows.filter((s) => s.status === 'active').length,
    trial: rows.filter((s) => s.status === 'trialing').length,
    attention: rows.filter((s) => actionNeeded(s) !== null).length,
  }
  const rev = revenue.data

  return (
    <div className="min-h-full bg-slate-100 p-4">
      <div className="mx-auto max-w-6xl space-y-4">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h1 className="text-lg font-semibold text-slate-800">Schools</h1>
            <p className="text-sm text-slate-500">
              {counts.total} total · {counts.paying} paying · {counts.trial} on trial ·{' '}
              <span className={counts.attention ? 'font-medium text-amber-700' : ''}>
                {counts.attention} need attention
              </span>
            </p>
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => run('Student counts refreshed.', refreshAllCounts)}
              disabled={act.isPending}
              className="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60"
            >
              Refresh counts
            </button>
            <button onClick={() => void signOut()} className="rounded px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-200">
              Sign out
            </button>
          </div>
        </header>

        {/* The books. `Outstanding` is deliberately NOT period-scoped — a
            receivable does not belong to the month it was raised in — and the
            label says so, because a figure next to two dates reads as being
            about those dates. */}
        <div className="rounded-lg border border-slate-200 bg-white p-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">The books</div>
            <div className="flex items-center gap-2 text-sm">
              <input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} className={FIELD} />
              <span className="text-slate-400">to</span>
              <input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} className={FIELD} />
            </div>
          </div>
          {revenue.error && <p className="mt-2 text-sm text-red-600">{(revenue.error as Error).message}</p>}
          <div className="mt-3 grid gap-3 sm:grid-cols-4">
            <Tile label="Invoiced" value={rev ? formatPkr(rev.invoiced) : '—'}
              hint="in the dates above" />
            <Tile label="Collected" value={rev ? formatPkr(rev.collected) : '—'}
              hint="money that actually arrived" />
            <Tile label="Given away" value={rev ? formatPkr(rev.discounted) : '—'}
              hint="list price minus what we charged"
              tone={rev && rev.discounted > 0 ? 'warn' : undefined} />
            <Tile label="Owed to us" value={rev ? formatPkr(rev.outstanding_total) : '—'}
              hint="all time, not just these dates"
              tone={rev && rev.outstanding_total > 0 ? 'warn' : undefined} />
          </div>
          {rev && rev.schools_owing.length > 0 && (
            <div className="mt-3 border-t border-slate-100 pt-2">
              <div className="text-xs text-slate-500">Who to chase</div>
              <div className="mt-1 flex flex-wrap gap-2">
                {rev.schools_owing.map((s) => (
                  <span key={s.school_id} className="rounded bg-amber-50 px-2 py-0.5 text-xs text-amber-900">
                    {s.school_name} · {formatPkr(s.outstanding)}
                  </span>
                ))}
              </div>
            </div>
          )}
        </div>

        <SchemaStrip state={schema.data} error={schema.error as Error | null} />

        {msg && <div className="rounded border border-emerald-200 bg-emerald-50 p-2 text-sm text-emerald-800">{msg}</div>}
        {err && <div className="rounded border border-red-200 bg-red-50 p-2 text-sm text-red-700">{err}</div>}

        {schools.isLoading && <div className="text-sm text-slate-500">Loading schools…</div>}
        {schools.error && <div className="text-sm text-red-600">{(schools.error as Error).message}</div>}

        {rows.length === 0 && !schools.isLoading && (
          <div className="rounded-lg border border-slate-200 bg-white p-6 text-center text-sm text-slate-500">
            No schools yet. They appear here as soon as someone signs up.
          </div>
        )}

        <div className="space-y-2">
          {rows.map((s) => {
            const todo = actionNeeded(s)
            return (
              <div key={s.school_id} className="rounded-lg border border-slate-200 bg-white p-3">
                <div className="flex flex-wrap items-start justify-between gap-3">
                  <div className="min-w-0">
                    <div className="flex items-center gap-2">
                      <span className="font-medium text-slate-800">{s.school_name}</span>
                      <span className={`rounded px-1.5 py-0.5 text-xs font-medium ${STATUS_STYLE[s.status]}`}>
                        {s.status}
                      </span>
                      {s.outstanding > 0 && (
                        <span className="rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                          owes {formatPkr(s.outstanding)}
                        </span>
                      )}
                    </div>
                    <div className="mt-0.5 text-xs text-slate-500">
                      {[s.city, s.contact_name, s.contact_phone].filter(Boolean).join(' · ') || 'No contact details'}
                    </div>
                    <div className="mt-1 text-sm text-slate-600">
                      {s.student_count.toLocaleString()} students
                      {s.student_limit !== null && <span className="text-slate-400"> / {s.student_limit.toLocaleString()}</span>}
                      {s.limit_state === 'over' && (
                        <span className="ml-2 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800">
                          over limit
                        </span>
                      )}
                      {s.limit_state === 'within_margin' && (
                        <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600">
                          in margin
                        </span>
                      )}
                      <span className="ml-2 text-slate-400">
                        {s.plan_code}
                        {s.expires_on && ` · ${s.days_left !== null && s.days_left >= 0
                          ? `${s.days_left}d left`
                          : `expired ${Math.abs(s.days_left ?? 0)}d ago`}`}
                      </span>
                      {s.last_paid_on && <span className="ml-2 text-slate-400">last paid {s.last_paid_on}</span>}
                    </div>
                    {todo && <div className="mt-1 text-sm font-medium text-amber-700">{todo}</div>}
                    <div className="mt-1 flex gap-3 text-xs">
                      <button onClick={() => setLedgerFor(s)} className="text-brand-700 hover:underline">
                        Statement
                      </button>
                      <button onClick={() => { setErr(null); setMsg(null); setPaying(s) }} className="text-brand-700 hover:underline">
                        Record payment
                      </button>
                    </div>
                  </div>

                  <SchoolActions
                    school={s}
                    plans={plans.data ?? []}
                    busy={act.isPending}
                    onActivate={(plan, months, amount, note, allowOverLimit) =>
                      run(
                        `${s.school_name} activated on ${plan} for ${months} month(s).`,
                        () => activateSubscription(s.school_id, plan, months,
                          { amount, note, allowOverLimit }),
                      )}
                    onExtend={() =>
                      run(`${s.school_name} trial extended by 14 days.`, () => extendTrial(s.school_id, 14))}
                  />
                </div>
              </div>
            )
          })}
        </div>
      </div>

      {paying && (
        <PaymentDialog
          school={paying}
          busy={act.isPending}
          onClose={() => setPaying(null)}
          onSave={(v) => {
            run(`${formatPkr(v.amount)} recorded for ${paying.school_name}.`,
              () => recordPlatformPayment({ schoolId: paying.school_id, ...v }))
            setPaying(null)
          }}
        />
      )}

      {ledgerFor && <LedgerDialog school={ledgerFor} onClose={() => setLedgerFor(null)} />}
    </div>
  )
}

/**
 * What schema this database is actually running.
 *
 * One line, because on a healthy day it is one fact and should not take up
 * space. It goes loud in exactly two cases, and both of them are the reason the
 * ledger was added:
 *
 *  - A GAP. A bundle applies as ONE transaction, so a bundle that dies halfway
 *    rolls back entirely and its migrations never arrive. That has already
 *    happened to a live school: fifteen migrations went missing and nobody
 *    learned until screens started failing at runtime.
 *
 *  - AN EMPTY LEDGER on a database that has the table. 0069 refuses to seed
 *    unless it can prove all six shipped bundles are present, so empty means
 *    "this database is incomplete and I would be lying if I gave you a number".
 */
function SchemaStrip({ state, error }: { state?: SchemaState; error: Error | null }) {
  // Before bundle 7 is pasted, fn_platform_schema_state does not exist and this
  // errors. Saying so plainly beats a blank space, because the fix is one paste.
  if (error) {
    return (
      <div className="rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
        <span className="font-medium">This database has no migration ledger.</span>{' '}
        Paste <code className="rounded bg-amber-100 px-1">supabase/bundles/7_ledger_and_limits.sql</code>{' '}
        into the Supabase SQL editor. Until then nothing records which migrations production has.
      </div>
    )
  }
  if (!state) return null

  if (state.applied_count === 0) {
    return (
      <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-900">
        <span className="font-medium">The migration ledger is empty.</span>{' '}
        0069 refused to record this database because it could not prove every shipped bundle is
        present. Run <code className="rounded bg-red-100 px-1">supabase/repair/detect.sql</code> and
        apply what it names.
      </div>
    )
  }

  const gaps = state.gaps_total > 0
  return (
    <div className={`rounded border px-3 py-2 text-sm ${
      gaps ? 'border-red-300 bg-red-50 text-red-900' : 'border-slate-200 bg-white text-slate-600'
    }`}>
      <span className="font-medium">Schema</span>{' '}
      {state.applied_count} migration{state.applied_count === 1 ? '' : 's'} applied
      {state.latest && <span className="text-slate-400"> · latest {state.latest.replace(/\.sql$/, '')}</span>}
      {gaps && (
        <div className="mt-1 font-medium">
          {state.gaps_total} missing in the middle: {state.gaps.join(', ')}
          {state.gaps_total > state.gaps.length && ` … and ${state.gaps_total - state.gaps.length} more`}.
          {' '}A bundle rolled back halfway — apply those migrations before anything else.
        </div>
      )}
    </div>
  )
}

function Tile({ label, value, hint, tone }: {
  label: string; value: string; hint?: string; tone?: 'warn'
}) {
  return (
    <div className={`rounded border p-2 ${tone === 'warn' ? 'border-amber-200 bg-amber-50' : 'border-slate-200'}`}>
      <div className="text-xs text-slate-500">{label}</div>
      <div className={`text-lg font-semibold ${tone === 'warn' ? 'text-amber-900' : 'text-slate-800'}`}>{value}</div>
      {hint && <div className="text-[11px] text-slate-400">{hint}</div>}
    </div>
  )
}

function SchoolActions({
  school, plans, busy, onActivate, onExtend,
}: {
  school: PlatformSchool
  plans: { code: string; name: string; price_yearly: number; price_monthly: number; student_limit: number | null }[]
  busy: boolean
  onActivate: (plan: string, months: number, amount: number | null, note: string | null, allowOverLimit: boolean) => void
  onExtend: () => void
}) {
  // Default to the plan their real headcount says they should be on, so the
  // common case is one click and the size question is already answered.
  const [plan, setPlan] = useState(school.suggested_plan || school.plan_code)
  const [months, setMonths] = useState(12)
  const [open, setOpen] = useState(false)
  const [amount, setAmount] = useState('')
  const [note, setNote] = useState('')
  const chosen = plans.find((p) => p.code === plan)
  const list = chosen ? (months >= 12 ? chosen.price_yearly * (months / 12) : chosen.price_monthly * months) : null
  const typed = amount.trim() === '' ? null : Number(amount)
  // The database refuses a non-list amount with no reason. Refusing here too
  // means the operator is told before pressing the button, not after.
  const needsNote = typed !== null && list !== null && typed !== list && !note.trim()
  // The database also refuses a plan the school has outgrown. Showing it up
  // front turns a red error into a decision.
  const wouldBeOver = chosen?.student_limit != null
    && school.student_count > Math.ceil(chosen.student_limit * 1.1)

  return (
    <div className="flex shrink-0 flex-col items-end gap-2">
      <div className="flex flex-wrap items-center gap-2">
        <select value={plan} onChange={(e) => setPlan(e.target.value)} className={FIELD}>
          {plans.map((p) => <option key={p.code} value={p.code}>{p.code}</option>)}
        </select>
        <select value={months} onChange={(e) => setMonths(Number(e.target.value))} className={FIELD}>
          <option value={1}>1 month</option>
          <option value={3}>3 months</option>
          <option value={6}>6 months</option>
          <option value={12}>1 year</option>
        </select>
        {list !== null && <span className="text-sm text-slate-500">{formatPkr(list)}</span>}
        <button
          onClick={() => onActivate(plan, months, typed, note.trim() || null, wouldBeOver)}
          disabled={busy || needsNote}
          className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
        >
          {school.status === 'active' ? 'Renew' : 'Activate'}
        </button>
        {(school.status === 'trialing' || school.status === 'locked') && (
          <button onClick={onExtend} disabled={busy}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-60">
            +14d trial
          </button>
        )}
        <button onClick={() => setOpen((v) => !v)} className="text-xs text-brand-700 hover:underline">
          {open ? 'hide price' : 'change price'}
        </button>
      </div>

      {wouldBeOver && (
        <div className="max-w-sm rounded border border-amber-300 bg-amber-50 px-2 py-1 text-right text-xs text-amber-900">
          {school.student_count.toLocaleString()} students against {plan}&rsquo;s limit of{' '}
          {chosen?.student_limit?.toLocaleString()}. {school.suggested_plan !== plan
            ? <>Pick <span className="font-semibold">{school.suggested_plan}</span>, or renew on {plan} anyway — the breach is recorded on the invoice.</>
            : <>Renewing anyway records the breach on the invoice.</>}
        </div>
      )}

      {open && (
        <div className="flex max-w-sm flex-col items-end gap-1">
          <div className="flex items-center gap-2">
            <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal"
              placeholder={list !== null ? `list ${list}` : 'amount'} className={`${FIELD} w-28 text-right`} />
            <input value={note} onChange={(e) => setNote(e.target.value)}
              placeholder="reason (goes on the invoice)" className={`${FIELD} w-56`} />
          </div>
          {needsNote && (
            <span className="text-xs text-amber-700">
              A price that is not the list price needs a reason — including zero.
            </span>
          )}
        </div>
      )}
    </div>
  )
}

function PaymentDialog({ school, busy, onClose, onSave }: {
  school: PlatformSchool
  busy: boolean
  onClose: () => void
  onSave: (v: { amount: number; paidOn: string; method: string; reference: string | null; note: string | null }) => void
}) {
  // Pre-filled with what they owe, which is the amount in almost every case.
  const [amount, setAmount] = useState(school.outstanding > 0 ? String(school.outstanding) : '')
  const [paidOn, setPaidOn] = useState(today())
  const [method, setMethod] = useState('bank')
  const [reference, setReference] = useState('')
  const [note, setNote] = useState('')
  const n = Number(amount)
  const valid = amount.trim() !== '' && Number.isFinite(n) && n > 0

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">Record a payment</h2>
        <p className="mt-1 text-sm text-slate-600">
          {school.school_name}
          {school.outstanding > 0
            ? <> · owes {formatPkr(school.outstanding)}</>
            : <> · nothing outstanding — this will show as credit</>}
        </p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-sm text-slate-600">Amount</span>
            <input autoFocus value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal"
              className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Received on</span>
            <input type="date" value={paidOn} max={today()} onChange={(e) => setPaidOn(e.target.value)}
              className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">How</span>
            <select value={method} onChange={(e) => setMethod(e.target.value)} className={`${FIELD} mt-1 w-full`}>
              <option value="bank">Bank transfer</option>
              <option value="cash">Cash</option>
              <option value="cheque">Cheque</option>
              <option value="online">Online</option>
              <option value="other">Other</option>
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Reference</span>
            {/* The only way to tie a row to a bank statement when a school says
                it paid and we cannot find it. */}
            <input value={reference} onChange={(e) => setReference(e.target.value)}
              placeholder="e.g. HBL-77123" className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block sm:col-span-2">
            <span className="text-sm text-slate-600">Note (optional)</span>
            <input value={note} onChange={(e) => setNote(e.target.value)} className={`${FIELD} mt-1 w-full`} />
          </label>
        </div>
        <div className="mt-4 flex gap-2">
          <button
            onClick={() => onSave({ amount: n, paidOn, method, reference: reference.trim() || null, note: note.trim() || null })}
            disabled={busy || !valid}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            Record
          </button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

function LedgerDialog({ school, onClose }: { school: PlatformSchool; onClose: () => void }) {
  const q = useQuery({
    queryKey: ['platformLedger', school.school_id],
    queryFn: () => platformLedger(school.school_id),
  })
  // A running balance, computed here rather than stored, so it can never
  // disagree with the rows above it.
  let bal = 0

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-2xl rounded-lg bg-white p-5 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-base font-semibold text-slate-800">{school.school_name}</h2>
            <p className="text-sm text-slate-600">
              Statement · {school.outstanding > 0
                ? <span className="font-medium text-amber-800">{formatPkr(school.outstanding)} outstanding</span>
                : 'nothing outstanding'}
            </p>
          </div>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>

        {q.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="mt-3 text-sm text-red-600">{(q.error as Error).message}</p>}

        {q.data && q.data.length === 0 && (
          <p className="mt-3 text-sm text-slate-500">
            Nothing invoiced yet. A charge is written when you activate or renew them.
          </p>
        )}

        {q.data && q.data.length > 0 && (
          <div className="mt-3 overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-2 py-2 w-28">Date</th>
                  <th className="px-2 py-2">What</th>
                  <th className="px-2 py-2 w-28 text-right">Charged</th>
                  <th className="px-2 py-2 w-28 text-right">Paid</th>
                  <th className="px-2 py-2 w-28 text-right">Balance</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {q.data.map((e, i) => {
                  bal += Number(e.charged ?? 0) - Number(e.paid ?? 0)
                  return (
                    <tr key={i}>
                      <td className="px-2 py-2 text-slate-500">{e.entry_date}</td>
                      <td className="px-2 py-2 text-slate-700">
                        {e.description}
                        {e.reference && <span className="text-slate-400"> · {e.reference}</span>}
                        {e.note && <div className="text-xs text-slate-500">{e.note}</div>}
                      </td>
                      <td className="px-2 py-2 text-right text-slate-700">{e.charged ? formatPkr(Number(e.charged)) : ''}</td>
                      <td className="px-2 py-2 text-right text-emerald-700">{e.paid ? formatPkr(Number(e.paid)) : ''}</td>
                      <td className="px-2 py-2 text-right font-medium text-slate-800">{formatPkr(bal)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}

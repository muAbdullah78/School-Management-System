import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  dueSoon, renewalMessage, markReminded,
  type DueSoonRow, type RenewalBucket, type ReminderStage,
} from '@/lib/platform'
import { whatsappLink } from '@/lib/db'
import { formatPkr } from '@/lib/licence'
import { fmtDate } from '@/lib/format'

/**
 * The renewal worklist.
 *
 * With three schools you know them by name. With fifty, a licence that expired
 * eleven days ago is row 34 of an alphabetical list, and the first anyone hears
 * of it is the principal phoning to say the software has locked, which is the
 * worst possible moment to open a renewal conversation: the school is angry, the
 * office is full of parents, and the vendor is the reason nobody can take a fee.
 *
 * So the list IS the worklist. Worst first, and the top of it is today's calls.
 *
 * TWO THINGS ARE DELIBERATELY ON THE ROW rather than a click away:
 *
 *   `unbilled_days`  the licence runs further than any invoice covers. That is
 *                    time given away, and until this screen existed nothing in
 *                    the product could see it.
 *   `needs_upgrade`  they have outgrown the plan. The renewal must be quoted at
 *                    the plan the count fits, or the conversation happens twice.
 */
const BUCKETS: { key: RenewalBucket; label: string; tone: string }[] = [
  { key: 'locked',    label: 'Stopped',        tone: 'border-red-300 bg-red-50 text-red-900' },
  { key: 'grace',     label: 'In grace',       tone: 'border-red-200 bg-red-50 text-red-800' },
  { key: 'overdue',   label: 'Overdue',        tone: 'border-red-200 bg-red-50 text-red-800' },
  { key: 'today',     label: 'Expires today',  tone: 'border-amber-300 bg-amber-50 text-amber-900' },
  { key: 'week',      label: 'This week',      tone: 'border-amber-200 bg-amber-50 text-amber-900' },
  { key: 'fortnight', label: 'Two weeks',      tone: 'border-slate-200 bg-white text-slate-800' },
  { key: 'month',     label: 'This month',     tone: 'border-slate-200 bg-white text-slate-800' },
  { key: 'later',     label: 'Later',          tone: 'border-slate-200 bg-white text-slate-600' },
  { key: 'cancelled', label: 'Cancelled',      tone: 'border-slate-200 bg-slate-50 text-slate-500' },
  { key: 'unknown',   label: 'No expiry set',  tone: 'border-slate-200 bg-slate-50 text-slate-500' },
]

export function Renewals({ onOpenSchool }: { onOpenSchool: (schoolId: string) => void }) {
  const [days, setDays] = useState(45)
  const [remind, setRemind] = useState<DueSoonRow | null>(null)
  const q = useQuery({ queryKey: ['dueSoon', days], queryFn: () => dueSoon(days) })

  const rows = q.data ?? []
  const groups = BUCKETS
    .map((b) => ({ ...b, rows: rows.filter((r) => r.bucket === b.key) }))
    .filter((g) => g.rows.length > 0)

  const owed = rows.reduce((s, r) => s + Number(r.outstanding || 0), 0)
  const unbilled = rows.filter((r) => (r.unbilled_days ?? 0) > 0)

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-800">
            {rows.length} licence(s) to deal with
          </h2>
          <p className="text-xs text-slate-500">
            Expiring within {days} days, plus everything already in grace, stopped or
            cancelled. Those are on the list whatever the window says.
          </p>
        </div>
        <label className="flex items-center gap-2 text-sm">
          <span className="text-slate-500">Window</span>
          <select value={days} onChange={(e) => setDays(Number(e.target.value))}
            className="rounded border border-slate-300 px-2 py-1 text-sm">
            <option value={14}>14 days</option>
            <option value={30}>30 days</option>
            <option value={45}>45 days</option>
            <option value={90}>90 days</option>
            <option value={365}>A year</option>
          </select>
        </label>
      </div>

      {q.error && <p className="text-sm text-red-600">{(q.error as Error).message}</p>}
      {q.isLoading && <p className="text-sm text-slate-500">Loading…</p>}

      {rows.length > 0 && (
        <div className="grid gap-3 sm:grid-cols-3">
          <Tile label="Owed by these schools" value={formatPkr(owed)}
            tone={owed > 0 ? 'warn' : undefined} />
          <Tile label="Need a bigger plan"
            value={String(rows.filter((r) => r.needs_upgrade).length)}
            hint="quoted at the right plan below" />
          <Tile label="Running on unbilled time" value={String(unbilled.length)}
            hint="licence reaches further than any invoice"
            tone={unbilled.length > 0 ? 'warn' : undefined} />
        </div>
      )}

      {!q.isLoading && rows.length === 0 && (
        <p className="rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
          Nothing to chase in the next {days} days.
        </p>
      )}

      {groups.map((g) => (
        <section key={g.key}>
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            {g.label} · {g.rows.length}
          </div>
          <div className="mt-1 space-y-2">
            {g.rows.map((r) => (
              <Row key={r.school_id} r={r} tone={g.tone}
                onOpen={() => onOpenSchool(r.school_id)}
                onRemind={() => setRemind(r)} />
            ))}
          </div>
        </section>
      ))}

      {remind && <RemindDialog row={remind} onClose={() => setRemind(null)} />}
    </div>
  )
}

function Row({ r, tone, onOpen, onRemind }: {
  r: DueSoonRow; tone: string; onOpen: () => void; onRemind: () => void
}) {
  const reminded = r.last_reminded_at
    ? Math.floor((Date.now() - new Date(r.last_reminded_at).getTime()) / 86_400_000)
    : null
  return (
    <div className={`rounded border px-3 py-2 ${tone}`}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <button onClick={onOpen} className="text-sm font-medium hover:underline">
            {r.school_name}
          </button>
          <div className="text-xs opacity-80">
            {[r.city, r.contact_name, r.contact_phone].filter(Boolean).join(' · ')}
          </div>
          <div className="mt-1 text-xs">
            {r.plan_code} ·{' '}
            {r.expires_on
              ? <>{r.days_left !== null && r.days_left >= 0
                    ? `${r.days_left} day(s) left`
                    : `expired ${Math.abs(r.days_left ?? 0)} day(s) ago`}
                  {' '}({fmtDate(r.expires_on)})</>
              : 'no expiry recorded'}
            {' · '}{r.student_count.toLocaleString()} students
            {r.student_limit !== null && ` / ${r.student_limit.toLocaleString()}`}
          </div>

          {/* The two facts that change what you say on the phone. */}
          {r.needs_upgrade && r.suggested_plan && (
            <div className="mt-1 text-xs font-medium">
              Outgrown {r.plan_code}: renew on {r.suggested_plan}
            </div>
          )}
          {(r.unbilled_days ?? 0) > 0 && (
            <div className="mt-1 text-xs font-medium">
              {r.unbilled_days} day(s) of licence were never invoiced
              {r.invoiced_to && `: invoices only reach ${fmtDate(r.invoiced_to)}`}
            </div>
          )}
          {r.never_invoiced && (
            <div className="mt-1 text-xs font-medium">
              Never invoiced at all. A trial, or a year given away
            </div>
          )}
          {r.outstanding > 0 && (
            <div className="mt-1 text-xs font-medium">
              {formatPkr(r.outstanding)} still owed
            </div>
          )}
        </div>

        <div className="shrink-0 text-right">
          {r.renewal_amount !== null && (
            <div className="text-sm font-semibold">{formatPkr(r.renewal_amount)}</div>
          )}
          <div className="text-xs opacity-70">to renew</div>
          <button onClick={onRemind}
            className="mt-1 rounded border border-current px-2 py-1 text-xs font-medium hover:opacity-80">
            Remind on WhatsApp
          </button>
          {reminded !== null && (
            <div className="mt-1 text-xs opacity-70">
              {reminded === 0 ? 'reminded today' : `reminded ${reminded}d ago`}
              {r.last_reminded_stage && ` (${r.last_reminded_stage})`}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

/**
 * The message, before it is sent.
 *
 * Shown rather than sent blind, and editable in the sense that the operator can
 * see exactly what the school will read. The stage is chosen from the licence:
 * a school in grace gets a different sentence from one a month out, and the
 * operator can override it, because sometimes you know something the dates do
 * not.
 *
 * "Mark as reminded" is a SEPARATE click from opening WhatsApp, and that is
 * honest: we know the chat was opened, we do not know a message was sent. A
 * screen that logged "reminded" the moment it rendered would fill the history
 * with reminders nobody sent.
 */
function RemindDialog({ row, onClose }: { row: DueSoonRow; onClose: () => void }) {
  const qc = useQueryClient()
  const [stage, setStage] = useState<ReminderStage | ''>('')
  const [err, setErr] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  const q = useQuery({
    queryKey: ['renewalMessage', row.school_id, stage],
    queryFn: () => renewalMessage(row.school_id, stage || undefined),
  })

  const mark = useMutation({
    mutationFn: async () => {
      if (!q.data) throw new Error('No message composed yet')
      await markReminded(row.school_id, q.data.stage)
    },
    onSuccess: () => {
      setDone(true)
      void qc.invalidateQueries({ queryKey: ['dueSoon'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  const m = q.data
  const link = m && m.phone_intl ? whatsappLink(m.phone_intl, m.text) : null

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-xl rounded-lg bg-white p-4 shadow-lg">
        <div className="flex items-start justify-between gap-3">
          <div>
            <h3 className="text-sm font-semibold text-slate-800">
              Remind {row.school_name}
            </h3>
            <p className="text-xs text-slate-500">
              WhatsApp, on your own number. No gateway, no per-message cost, and no
              delivery report to pretend we have.
            </p>
          </div>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>

        {q.error && <p className="mt-3 text-sm text-red-600">{(q.error as Error).message}</p>}
        {err && <p className="mt-3 text-sm text-red-600">{err}</p>}

        {m && (
          <>
            <label className="mt-3 block text-xs font-medium text-slate-600">
              Tone
              <select value={stage} onChange={(e) => setStage(e.target.value as ReminderStage | '')}
                className="mt-0.5 w-full rounded border border-slate-300 px-2 py-1.5 text-sm">
                <option value="">Chosen from the licence ({m.stage})</option>
                <option value="ahead">A month out: no urgency</option>
                <option value="due">Due soon: names the date and amount</option>
                <option value="today">Expires today</option>
                <option value="grace">Expired, still working</option>
                <option value="locked">Stopped</option>
              </select>
            </label>

            <div className="mt-3 whitespace-pre-wrap rounded border border-slate-200 bg-slate-50 p-3 text-sm text-slate-800">
              {m.text}
            </div>

            {m.no_phone_reason ? (
              <p className="mt-3 rounded bg-amber-50 px-3 py-2 text-sm text-amber-900">
                {m.no_phone_reason}. Copy the message above and send it however you
                reach them.
              </p>
            ) : (
              <div className="mt-3 flex flex-wrap items-center gap-2">
                <a href={link ?? '#'} target="_blank" rel="noreferrer"
                  className="rounded bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-700">
                  Open WhatsApp to {m.phone}
                </a>
                <button onClick={() => mark.mutate()} disabled={mark.isPending || done}
                  className="rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50 disabled:opacity-60">
                  {done ? 'Recorded' : 'Mark as reminded'}
                </button>
              </div>
            )}

            <p className="mt-2 text-xs text-slate-400">
              Marking it as reminded records that you opened the chat, not that the
              school read it. It is there so nobody chases the same school twice in a
              morning.
            </p>
          </>
        )}
      </div>
    </div>
  )
}

function Tile({ label, value, hint, tone }: {
  label: string; value: string; hint?: string; tone?: 'warn'
}) {
  return (
    <div className={`rounded border p-3 ${
      tone === 'warn' ? 'border-amber-200 bg-amber-50' : 'border-slate-200 bg-white'}`}>
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className={`text-lg font-semibold ${
        tone === 'warn' ? 'text-amber-900' : 'text-slate-800'}`}>{value}</div>
      {hint && <div className="text-xs text-slate-400">{hint}</div>}
    </div>
  )
}

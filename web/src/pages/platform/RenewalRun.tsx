import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { renewalRuns, runRenewals, type RenewalRun, type RenewalAttempt } from '@/lib/platform'
import { formatPkr } from '@/lib/licence'
import { fmtDateTime } from '@/lib/format'
import { Chip } from './status'

/**
 * Raising the bills, without anybody having to remember.
 *
 * WHY THIS EXISTS. Every renewal invoice in this product existed because
 * somebody opened this tab and pressed a button on a row. The failure mode is
 * not a bug, it is a Tuesday: the operator is on a call, the list is not
 * opened, and a school's period ends with no invoice ever raised. It then
 * lapses into grace and finally locks, having never been asked for money.
 *
 * PREVIEW FIRST, AND THAT IS THE DEFAULT. The button that changes nothing is
 * the primary one and it is on the left. Billing is behind a second press that
 * only appears once the preview has been read, and it says how many invoices it
 * is about to raise. A batch job that moves money and opens with "go" is one
 * somebody runs by accident while exploring, which is what a new operator does
 * first.
 *
 * IT RAISES INVOICES AND DOES NOT TAKE MONEY. Said on the screen, because the
 * two are easy to conflate and the difference matters: the bill is owed by
 * every school whose period has ended, whatever it pays with, and collection is
 * a separate step that does not exist yet.
 */
export function RenewalRunStrip() {
  const qc = useQueryClient()
  const [result, setResult] = useState<RenewalRun | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [showHistory, setShowHistory] = useState(false)

  const go = useMutation({
    mutationFn: (dry: boolean) => runRenewals(dry),
    onSuccess: (r) => {
      setErr(null); setResult(r)
      if (!r.dry_run) {
        // Everything on screen was about who owes what, and that has just
        // changed. Invalidated by key rather than clearing the cache, because
        // the school list and the books are both wrong now and nothing else is.
        void qc.invalidateQueries({ queryKey: ['platformSchools'] })
        void qc.invalidateQueries({ queryKey: ['dueSoon'] })
        void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
        void qc.invalidateQueries({ queryKey: ['platformLedger'] })
        void qc.invalidateQueries({ queryKey: ['renewalRuns'] })
      }
    },
    onError: (e) => setErr((e as Error).message),
  })

  const preview = result?.dry_run === true ? result : null
  const done = result?.dry_run === false ? result : null

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-3">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Raise the bills that are due
          </div>
          <p className="mt-0.5 max-w-prose text-sm text-slate-600">
            Every school whose paid period has ended gets its invoice. It raises
            invoices, it does not take money: nothing is charged to anybody, and
            running it twice bills nobody twice.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          <button onClick={() => go.mutate(true)} disabled={go.isPending}
            className="rounded border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
            {go.isPending && preview === null ? 'Checking…' : 'Show me who is due'}
          </button>
          {/* ONLY AFTER THE PREVIEW. There is no way to reach this button
              without having first seen the list it is about to bill. */}
          {preview && preview.considered > 0 && (
            <button onClick={() => go.mutate(false)} disabled={go.isPending}
              className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {go.isPending ? 'Raising…' : `Raise ${countBillable(preview)} invoice(s)`}
            </button>
          )}
          <button onClick={() => setShowHistory(!showHistory)}
            className="rounded px-2 py-1.5 text-sm text-slate-500 hover:bg-slate-100">
            {showHistory ? 'Hide past runs' : 'Past runs'}
          </button>
        </div>
      </div>

      {err && (
        <p className="mt-2 rounded border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {err}
        </p>
      )}

      {result && (
        <div className={`mt-3 rounded border p-3 ${
          done ? 'border-money-200 bg-money-50' : 'border-slate-200 bg-slate-50'}`}>
          <p className="text-sm font-medium text-slate-800">{result.note}</p>
          {result.attempts.length === 0 && (
            <p className="mt-1 text-sm text-slate-500">Nothing is due today.</p>
          )}
          {result.attempts.length > 0 && (
            <ul className="mt-2 divide-y divide-slate-200/70">
              {result.attempts.map((a, i) => <AttemptRow key={i} a={a} />)}
            </ul>
          )}
        </div>
      )}

      {showHistory && <History />}
    </div>
  )
}

/**
 * How many of the previewed schools would actually be billed.
 *
 * NOT `considered`. The preview counts every school it looked at, including the
 * trials that never said yes and the ones that have outgrown their plan, and a
 * button reading "Raise 7 invoices" that raises four is a button that has lied
 * about what it is going to do.
 */
function countBillable(r: RenewalRun): number {
  return r.attempts.filter((a) => a.outcome === 'would_invoice').length
}

const TONE: Record<RenewalAttempt['outcome'], Parameters<typeof Chip>[0]['tone']> = {
  would_invoice: 'trial',
  invoiced: 'live',
  already_invoiced: 'quiet',
  needs_decision: 'warn',
  trial_never_said_yes: 'quiet',
  failed: 'stopped',
}

const LABEL: Record<RenewalAttempt['outcome'], string> = {
  would_invoice: 'would bill',
  invoiced: 'invoiced',
  already_invoiced: 'already billed',
  needs_decision: 'needs you',
  trial_never_said_yes: 'trial lapsed',
  failed: 'failed',
}

function AttemptRow({ a }: { a: RenewalAttempt }) {
  return (
    <li className="flex flex-wrap items-start gap-x-3 gap-y-1 py-1.5 text-sm">
      <Chip tone={TONE[a.outcome] ?? 'quiet'}>{LABEL[a.outcome] ?? a.outcome}</Chip>
      <span className="font-medium text-slate-800">{a.school_name}</span>
      {a.amount !== null && (
        <span className="tabular-nums text-slate-600">{formatPkr(a.amount)}</span>
      )}
      {/* The MESSAGE, not just the outcome. "Why was this school not billed" is
          a question that gets asked, and the answer has to be readable without
          opening anything. */}
      {a.message && (
        <span className="w-full text-xs text-slate-500 sm:w-auto sm:flex-1">{a.message}</span>
      )}
    </li>
  )
}

function History() {
  const q = useQuery({ queryKey: ['renewalRuns'], queryFn: () => renewalRuns(10) })
  if (q.isLoading) return <p className="mt-3 text-sm text-slate-500">Loading…</p>
  if (q.error) {
    return <p className="mt-3 text-sm text-danger-600">{(q.error as Error).message}</p>
  }
  const runs = q.data ?? []
  if (runs.length === 0) {
    return <p className="mt-3 text-sm text-slate-500">This has never been run.</p>
  }
  return (
    <div className="mt-3 border-t border-slate-200 pt-2">
      <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        Past runs
      </div>
      <ul className="mt-1.5 divide-y divide-slate-100">
        {runs.map((r) => (
          <li key={r.id} className="flex flex-wrap items-baseline gap-x-3 gap-y-0.5 py-1.5 text-sm">
            <span className="text-slate-500">{fmtDateTime(r.started_at)}</span>
            {r.dry_run && <Chip tone="quiet">preview only</Chip>}
            <span className="text-slate-800">
              {r.considered} due
              {!r.dry_run && <>, {r.invoiced} invoiced</>}
              {r.failed > 0 && <span className="text-danger-700">, {r.failed} failed</span>}
            </span>
            {/* WHO RAN IT. A batch job that moves money and does not record who
                started it is a job nobody can be answerable for. */}
            <span className="text-xs text-slate-400">
              {r.triggered_by_email ?? 'no signed-in operator'}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

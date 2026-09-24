/**
 * Money accepted and not yet cleared: bank challans, cheques and wallet
 * transfers logged with a receipt number but not counted anywhere until
 * somebody confirms the money arrived.
 *
 * WHAT CHANGED IN STEP 2, AND WHY
 *
 *   * VERIFY WAS ONE CLICK. Verifying applies the money to the child's
 *     challans and makes the receipt real, and it sat one tap away from
 *     Cancel on a phone. A bounced cheque verified by a stray tap is money
 *     the books now say came in. It asks first, and says what it will do.
 *   * NOTHING ELSE REFRESHED. Verifying changed the month's counts, the day
 *     at the counter, arrears and the family's balance, and only this list
 *     and "defaulters" (a screen that no longer exists) were re-read, so every
 *     other figure stayed wrong until a reload.
 *   * A FAILED READ LOOKED LIKE NOTHING PENDING. The list simply did not
 *     render, and a clerk reads an empty screen as "all cleared".
 *   * A FAMILY PAYMENT READ "-". It has no student, only a father, and the
 *     payer column was the student's name.
 *   * HOW LONG IT HAS WAITED. A challan pending for three weeks has almost
 *     certainly bounced or been forgotten, and that is the row to chase.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listPendingPayments, verifyPayment, cancelPendingPayment, type PendingPaymentRow } from '@/lib/db'
import { PAYMENT_METHODS } from '@/lib/constants'
import { fmtPKR, fmtDate, todayISO } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'

const methodLabel = (m: string) => PAYMENT_METHODS.find((x) => x.value === m)?.label ?? m

function daysWaiting(createdAt: string): number {
  const [y, m, d] = todayISO().split('-').map(Number)
  const then = new Date(createdAt)
  return Math.max(0, Math.floor((Date.UTC(y, m - 1, d) - Date.UTC(then.getFullYear(), then.getMonth(), then.getDate())) / 86_400_000))
}

function payer(p: PendingPaymentRow): string {
  return p.student_name ?? (p.family_head ? `${p.family_head} (family)` : 'Unknown payer')
}

function Waited({ days }: { days: number }) {
  const cls = days >= 14 ? 'bg-danger-50 text-danger-700 ring-danger-100'
    : days >= 7 ? 'bg-due-50 text-due-800 ring-due-100'
    : 'bg-slate-50 text-slate-600 ring-slate-200'
  return (
    <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ${cls}`}>
      {days === 0 ? 'today' : `${days} day${days === 1 ? '' : 's'}`}
    </span>
  )
}

export function PendingClearances() {
  const qc = useQueryClient()
  // Was window.prompt, whose answer was passed through unchecked: an empty
  // string reached fn_cancel_pending_payment as the reason for cancelling a
  // receipt, and pressing Cancel in the browser dialog looked identical to
  // pressing Cancel in the app.
  const [cancelling, setCancelling] = useState<PendingPaymentRow | null>(null)
  const [verifying, setVerifying] = useState<PendingPaymentRow | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const list = useQuery({ queryKey: ['pendingPayments'], queryFn: listPendingPayments })

  // Everything that reads money. Verifying moves the child's balance, the
  // month's counts, the day's takings, arrears and the family sheet.
  const refreshMoney = () => {
    for (const k of ['pendingPayments', 'feesMonth', 'feesMonthPupils', 'feesToday', 'arrears',
      'familySheet', 'classDues', 'recentPayments', 'dashboardSummary', 'counterSummary',
      'profitSnapshot', 'financeSummary', 'balance', 'invoices', 'ledger']) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }

  const verify = useMutation({
    mutationFn: (p: PendingPaymentRow) => verifyPayment(p.id),
    onSuccess: (_d, p) => {
      setVerifying(null)
      setDone(`Verified: ${fmtPKR(p.amount)} from ${payer(p)} is now counted${p.receipt_no != null ? `, receipt #${p.receipt_no}` : ''}.`)
      refreshMoney()
    },
  })
  const cancel = useMutation({
    mutationFn: (v: { id: string; reason: string }) => cancelPendingPayment(v.id, v.reason),
    onSuccess: () => {
      setCancelling(null)
      setDone('Cancelled. It never counted, so no balance moved.')
      refreshMoney()
    },
  })

  const rows = list.data ?? []
  const total = rows.reduce((s, p) => s + p.amount, 0)
  const stale = rows.filter((p) => daysWaiting(p.created_at) >= 7)

  return (
    <div>
      <p className="text-sm text-slate-600">
        Bank challans, cheques and wallet transfers that were recorded but not yet cleared. A pending payment
        has a receipt number but <span className="font-medium">does not count</span> toward any balance,
        collection or day book until you verify it.
      </p>

      {list.isError && (
        <div className="mt-3 rounded-xl border border-danger-200 bg-danger-50 px-4 py-3 text-sm text-danger-800">
          <p className="font-medium text-danger-900">The pending list could not be loaded</p>
          <p className="mt-1">{(list.error as Error).message}. This does not mean nothing is pending.</p>
        </div>
      )}
      {list.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}

      {list.data && (
        <>
          <div className="mt-4 grid grid-cols-3 gap-2 sm:gap-3">
            <div className={`rounded-2xl border px-3 py-2.5 sm:px-4 sm:py-3 ${rows.length ? 'border-due-200 bg-due-50 text-due-900' : 'border-slate-200 bg-white text-slate-900'}`}>
              <div className="text-lg font-semibold tabular-nums sm:text-2xl">{rows.length}</div>
              <div className="text-xs font-medium leading-tight sm:text-sm">Waiting to clear</div>
            </div>
            <div className="rounded-2xl border border-slate-200 bg-white px-3 py-2.5 text-slate-900 sm:px-4 sm:py-3">
              <div className="text-lg font-semibold tabular-nums sm:text-2xl">{fmtPKR(total)}</div>
              <div className="text-xs font-medium leading-tight sm:text-sm">Not counted yet</div>
            </div>
            <div className={`rounded-2xl border px-3 py-2.5 sm:px-4 sm:py-3 ${stale.length ? 'border-danger-200 bg-danger-50 text-danger-900' : 'border-slate-200 bg-white text-slate-900'}`}>
              <div className="text-lg font-semibold tabular-nums sm:text-2xl">{stale.length}</div>
              <div className="text-xs font-medium leading-tight sm:text-sm">A week or more</div>
              <div className="mt-0.5 hidden text-xs opacity-75 sm:block">{stale.length ? 'Check these with the bank.' : 'Nothing has been waiting long.'}</div>
            </div>
          </div>

          {done && <p className="mt-3 rounded-xl bg-brand-50 px-3 py-2 text-sm text-brand-800">{done}</p>}

          {rows.length === 0 ? (
            <p className="mt-4 rounded-xl border border-money-200 bg-money-50 px-4 py-4 text-center text-sm text-money-800">
              Nothing pending: every payment is cleared.
            </p>
          ) : (
            <ul className="mt-4 divide-y divide-slate-100 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-card">
              {rows.map((p) => (
                <li key={p.id} className="flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3">
                  <div className="min-w-0 basis-full sm:basis-auto sm:flex-1">
                    <div className="flex items-baseline justify-between gap-3">
                      <span className="min-w-0 truncate text-sm font-medium text-slate-800">
                        {payer(p)}
                        {p.gr_no && <span className="font-normal text-slate-400"> · {p.gr_no}</span>}
                      </span>
                      <span className="shrink-0 text-sm font-semibold tabular-nums text-slate-900 sm:hidden">{fmtPKR(p.amount)}</span>
                    </div>
                    <div className="text-xs text-slate-500">
                      {p.receipt_no != null ? `#${p.receipt_no} · ` : ''}{methodLabel(p.method)} · {fmtDate(p.created_at)}
                      {p.note ? ` · ${p.note}` : ''}
                    </div>
                  </div>
                  <Waited days={daysWaiting(p.created_at)} />
                  <span className="hidden w-28 text-right text-sm font-semibold tabular-nums text-slate-900 sm:inline">{fmtPKR(p.amount)}</span>
                  <span className="ml-auto flex shrink-0 gap-2 sm:ml-0">
                    <button onClick={() => { setDone(null); setVerifying(p) }} disabled={verify.isPending}
                      className="rounded-lg bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-50">
                      Verify
                    </button>
                    <button onClick={() => { setDone(null); setCancelling(p) }} disabled={cancel.isPending}
                      className="rounded-lg border border-danger-200 px-3 py-1.5 text-xs font-medium text-danger-700 hover:bg-danger-50 disabled:opacity-50">
                      Cancel
                    </button>
                  </span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}

      {verifying && (
        <AskDialog
          title="Has this money reached the school?"
          intro={<>
            <b>{fmtPKR(verifying.amount)}</b> by {methodLabel(verifying.method)} from {payer(verifying)}
            {verifying.receipt_no != null ? `, receipt #${verifying.receipt_no}` : ''}. Verify only once the bank or
            wallet shows it. It is then applied to the oldest unpaid months and counted in today&rsquo;s takings.
          </>}
          confirmLabel="Yes, it has cleared"
          busy={verify.isPending}
          error={verify.error ? (verify.error as Error).message : null}
          onCancel={() => setVerifying(null)}
          onSubmit={() => verify.mutate(verifying)}
        />
      )}

      {cancelling && (
        <AskDialog
          title="Cancel this pending payment"
          intro={<>
            Receipt {cancelling.receipt_no != null ? `#${cancelling.receipt_no}` : ''} for{' '}
            <b>{fmtPKR(cancelling.amount)}</b> from {payer(cancelling)}. It never counted toward the balance, so
            nothing is reversed; the record is marked cancelled with the reason you give.
          </>}
          reason={{ label: 'Reason for cancelling', required: true, minLength: 4,
                    placeholder: 'e.g. bank challan bounced' }}
          confirmLabel="Cancel payment" tone="danger"
          busy={cancel.isPending} error={cancel.error ? (cancel.error as Error).message : null}
          onCancel={() => setCancelling(null)}
          onSubmit={(v) => cancel.mutate({ id: cancelling.id, reason: v.reason })}
        />
      )}
    </div>
  )
}

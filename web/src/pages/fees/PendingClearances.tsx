import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listPendingPayments, verifyPayment, cancelPendingPayment } from '@/lib/db'
import { PAYMENT_METHODS } from '@/lib/constants'
import { fmtPKR, fmtDate } from '@/lib/format'
import { AskDialog } from '@/components/AskDialog'

export function PendingClearances() {
  const qc = useQueryClient()
  // Was window.prompt, whose answer was passed through unchecked: an empty
  // string reached fn_cancel_pending_payment as the reason for cancelling a
  // receipt, and pressing Cancel in the browser dialog looked identical to
  // pressing Cancel in the app.
  const [cancelling, setCancelling] = useState<
    null | { id: string; amount: number; receiptNo: number | null }
  >(null)
  const list = useQuery({ queryKey: ['pendingPayments'], queryFn: listPendingPayments })

  const verify = useMutation({
    mutationFn: (id: string) => verifyPayment(id),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['pendingPayments'] })
      qc.invalidateQueries({ queryKey: ['defaulters'] })
    },
  })
  const cancel = useMutation({
    mutationFn: (v: { id: string; reason: string }) => cancelPendingPayment(v.id, v.reason),
    onSuccess: () => { setCancelling(null); qc.invalidateQueries({ queryKey: ['pendingPayments'] }) },
  })

  const total = list.data?.reduce((s, p) => s + p.amount, 0) ?? 0
  const err = (verify.error ?? cancel.error) as Error | null

  return (
    <div>
      <p className="text-sm text-slate-600">
        Bank challans and wallet transfers that were recorded but not yet cleared. A pending payment has a receipt
        number but <span className="font-medium">does not count</span> toward the balance, collections, or day-book
        until you verify it.
      </p>

      {list.isLoading && <p className="mt-3 text-sm text-slate-500">Loading…</p>}
      {list.data && (
        <>
          <div className="mt-3 flex items-center gap-4 text-sm">
            <span className="rounded bg-slate-100 px-2 py-1 text-slate-700">{list.data.length} pending</span>
            <span className="rounded bg-amber-50 px-2 py-1 font-medium text-amber-700">Awaiting clearance: {fmtPKR(total)}</span>
          </div>
          <div className="mt-3 overflow-x-auto rounded-lg bg-white shadow-sm ring-1 ring-slate-200">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2">Receipt</th><th className="px-3 py-2">Date</th>
                  <th className="px-3 py-2">Student</th><th className="px-3 py-2">Method</th>
                  <th className="px-3 py-2 text-right">Amount</th><th className="px-3 py-2 w-40"></th>
                </tr>
              </thead>
              <tbody>
                {list.data.map((p) => (
                  <tr key={p.id} className="border-t border-slate-100">
                    <td className="px-3 py-2 text-slate-500">{p.receipt_no != null ? `#${p.receipt_no}` : '-'}</td>
                    <td className="px-3 py-2 text-slate-500">{fmtDate(p.created_at)}</td>
                    <td className="px-3 py-2 text-slate-800">{p.student_name ?? '-'}<span className="text-slate-400">{p.gr_no ? ` · ${p.gr_no}` : ''}</span></td>
                    <td className="px-3 py-2 text-slate-600">{PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method}</td>
                    <td className="px-3 py-2 text-right font-semibold text-slate-800">{fmtPKR(p.amount)}</td>
                    <td className="px-3 py-2 text-right whitespace-nowrap">
                      <button onClick={() => verify.mutate(p.id)} disabled={verify.isPending}
                        className="text-sm text-emerald-700 hover:underline disabled:opacity-50">Verify</button>
                      <button onClick={() => setCancelling({ id: p.id, amount: p.amount, receiptNo: p.receipt_no })}
                        disabled={cancel.isPending}
                        className="ml-3 text-sm text-red-600 hover:underline disabled:opacity-50">Cancel</button>
                    </td>
                  </tr>
                ))}
                {list.data.length === 0 && (
                  <tr><td colSpan={6} className="px-3 py-4 text-center text-slate-400">Nothing pending: all payments are cleared.</td></tr>
                )}
              </tbody>
            </table>
          </div>
          {err && <p className="mt-2 text-sm text-red-600">{err.message}</p>}
        </>
      )}

      {cancelling && (
        <AskDialog
          title="Cancel this pending payment"
          intro={<>
            Receipt {cancelling.receiptNo != null ? `#${cancelling.receiptNo}` : ''} for{' '}
            <b>{fmtPKR(cancelling.amount)}</b>. It never counted toward the balance, so nothing is
            reversed; the record is marked cancelled with the reason you give.
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

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, getStudentBalance, getStudentInvoices, getStudentPayments,
  recordPayment, applyFine, waiveFine, addAdjustment, reversePayment, type StudentRow,
} from '@/lib/db'
import { PAYMENT_METHODS, PAYMENT_STATUS_LABELS } from '@/lib/constants'
import { fmtPKR, fmtDate } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { APPROVER_ROLES, type Role } from '@/auth/roles'
import { Receipt, type ReceiptData } from '@/components/Receipt'
import { AskDialog } from '@/components/AskDialog'
import { Avatar } from '@/components/Avatar'
import { useStudentFaces } from '@/hooks/useStudentFaces'

export function CollectPayment() {
  const [term, setTerm] = useState('')
  const [selected, setSelected] = useState<StudentRow | null>(null)
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')
  const [pending, setPending] = useState(false)
  const [pendingMsg, setPendingMsg] = useState<string | null>(null)
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)
  /**
   * Which "why?" dialog is open, if any.
   *
   * These four actions all used to be window.prompt chains: the adjustment one
   * asked three questions in a row with no idea whose balance it was moving, and
   * Chrome offers to suppress further dialogs after the second, at which point
   * prompt() returns null for ever and the button silently does nothing.
   */
  const [ask, setAsk] = useState<
    | null
    | { kind: 'fine'; invoiceId: string; label: string }
    | { kind: 'waive'; invoiceId: string; label: string }
    | { kind: 'adjust' }
    | { kind: 'reverse'; paymentId: string; amount: number; receiptNo: number | null }
  >(null)
  const qc = useQueryClient()

  const results = useQuery({
    queryKey: ['studentSearch', term],
    queryFn: () => searchStudents(term),
    enabled: term.trim().length >= 2 && !selected,
  })

  /**
   * Faces, on the screen where getting the wrong child costs the most.
   *
   * The roster has shown a photograph for a while, with the reason written on
   * it: four boys called Muhammad Ali in one school is ordinary here. This
   * screen searches the same pupils, shows the same three lines of text, and
   * had no face on it, and it is the one where picking the wrong one credits
   * another family's account and sends the receipt home with them.
   *
   * The selected child is included, not just the search results, so the face
   * stays visible while the money is being keyed rather than disappearing at
   * the moment it matters.
   */
  const faces = useStudentFaces([
    ...(results.data ?? []).map((r) => r.id),
    ...(selected ? [selected.id] : []),
  ])

  const sid = selected?.id
  const balance = useQuery({ queryKey: ['balance', sid], queryFn: () => getStudentBalance(sid!), enabled: !!sid })
  const invoices = useQuery({ queryKey: ['invoices', sid], queryFn: () => getStudentInvoices(sid!), enabled: !!sid })
  const payments = useQuery({ queryKey: ['payments', sid], queryFn: () => getStudentPayments(sid!), enabled: !!sid })

  const { profile } = useAuth()
  const canApprove = !!profile && APPROVER_ROLES.includes(profile.role as Role)

  function refresh() {
    qc.invalidateQueries({ queryKey: ['balance', sid] })
    qc.invalidateQueries({ queryKey: ['invoices', sid] })
    qc.invalidateQueries({ queryKey: ['payments', sid] })
  }

  const pay = useMutation({
    mutationFn: () => recordPayment(sid!, Number(amount), method, note || undefined, pending),
    onSuccess: async (res) => {
      if (pending) {
        setPendingMsg(`Recorded as pending (receipt #${res.receipt_no}). It won’t count until verified in the Pending tab.`)
        setAmount(''); setNote('')
        refresh()
        return
      }
      const newBalance = await getStudentBalance(sid!)
      setReceipt({
        receiptNo: res.receipt_no,
        studentName: selected!.full_name,
        grNo: selected!.gr_no,
        amount: Number(amount),
        method: PAYMENT_METHODS.find((m) => m.value === method)?.label ?? method,
        balanceAfter: newBalance,
        note: note || null,
      })
      setAmount(''); setNote('')
      refresh()
    },
  })

  const done = () => { refresh(); setAsk(null) }
  const fineM = useMutation({ mutationFn: (v: { invoiceId: string; amount: number; reason: string }) => applyFine(v.invoiceId, v.amount, v.reason), onSuccess: done })
  const waiveM = useMutation({ mutationFn: (v: { invoiceId: string; reason: string }) => waiveFine(v.invoiceId, v.reason), onSuccess: done })
  const adjustM = useMutation({ mutationFn: (v: { amount: number; reason: string }) => addAdjustment(sid!, v.amount, v.reason), onSuccess: done })
  const reverseM = useMutation({ mutationFn: (v: { id: string; reason: string }) => reversePayment(v.id, v.reason), onSuccess: done })
  const actionErr = (fineM.error ?? waiveM.error ?? adjustM.error ?? reverseM.error) as Error | null
  const asking = fineM.isPending || waiveM.isPending || adjustM.isPending || reverseM.isPending
  function onReprint(p: { receipt_no: number | null; amount: number; method: string; note: string | null }) {
    setReceipt({
      receiptNo: p.receipt_no ?? 0, studentName: selected!.full_name, grNo: selected!.gr_no,
      amount: p.amount, method: PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method,
      balanceAfter: balance.data ?? 0, note: p.note,
    })
  }

  function reset() {
    setSelected(null); setTerm(''); setAmount(''); setNote(''); setPending(false); setPendingMsg(null)
  }

  if (!selected) {
    return (
      <div>
        <label className="block max-w-md">
          <span className="text-sm text-slate-600">Search student by name or GR number</span>
          <input
            autoFocus value={term} onChange={(e) => setTerm(e.target.value)}
            placeholder="e.g. Ahmed or GR-001"
            className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </label>
        <div className="mt-3 max-w-md divide-y divide-slate-100 rounded border border-slate-200 bg-white">
          {results.isLoading && <div className="p-3 text-sm text-slate-500">Searching…</div>}
          {results.data?.length === 0 && term.trim().length >= 2 && (
            <div className="p-3 text-sm text-slate-500">No students found.</div>
          )}
          {results.data?.map((s) => (
            <button key={s.id} onClick={() => setSelected(s)}
              className="flex w-full items-center gap-2.5 px-3 py-2 text-left text-sm hover:bg-slate-50">
              <Avatar name={s.full_name} url={faces.data?.get(s.id) ?? null} size="sm" />
              <span className="min-w-0">
                <span className="font-medium text-slate-800">{s.full_name}</span>
                {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
                {s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
              </span>
            </button>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-3">
          <Avatar name={selected.full_name} url={faces.data?.get(selected.id) ?? null} size="md" />
          <div className="min-w-0">
            <div className="text-base font-semibold text-slate-800">{selected.full_name}</div>
            <div className="text-xs text-slate-500">{selected.father_name} · {selected.gr_no ?? 'no GR'}</div>
          </div>
        </div>
        <button onClick={reset} className="shrink-0 text-sm text-brand-700 hover:underline">Change student</button>
      </div>

      <div className="grid gap-4 md:grid-cols-2">
        {/* Balance + payment form */}
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Current balance</div>
          <div className={`mt-1 text-2xl font-semibold ${(balance.data ?? 0) > 0 ? 'text-red-600' : 'text-emerald-600'}`}>
            {balance.isLoading ? '…' : fmtPKR(balance.data ?? 0)}
          </div>
          <form
            className="mt-4 space-y-3"
            onSubmit={(e) => { e.preventDefault(); if (Number(amount) > 0) pay.mutate() }}
          >
            <label className="block">
              <span className="text-sm text-slate-600">Amount received</span>
              <input
                type="number" min="1" step="1" required value={amount} onChange={(e) => setAmount(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </label>
            <label className="block">
              <span className="text-sm text-slate-600">Method</span>
              <select value={method} onChange={(e) => setMethod(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none">
                {PAYMENT_METHODS.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
              </select>
            </label>
            <label className="block">
              <span className="text-sm text-slate-600">Note (optional)</span>
              <input value={note} onChange={(e) => setNote(e.target.value)}
                className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500" />
            </label>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" className="h-4 w-4" checked={pending} onChange={(e) => setPending(e.target.checked)} />
              Not cleared yet (pending: e.g. bank challan)
            </label>
            {pay.isError && <p className="text-sm text-red-600">{(pay.error as Error).message}</p>}
            {pendingMsg && <p className="rounded bg-amber-50 p-2 text-sm text-amber-700">{pendingMsg}</p>}
            <button type="submit" disabled={pay.isPending || !(Number(amount) > 0)}
              className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {pay.isPending ? 'Recording…' : pending ? 'Record as pending' : 'Record payment & print receipt'}
            </button>
          </form>
          {canApprove && (
            <button onClick={() => setAsk({ kind: 'adjust' })} disabled={asking}
              className="mt-2 w-full rounded border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-600 hover:bg-slate-50 disabled:opacity-60">
              Adjust balance (credit / correction)
            </button>
          )}
          {actionErr && <p className="mt-2 text-sm text-red-600">{actionErr.message}</p>}
        </div>

        {/* Open invoices */}
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Invoices</div>
          <div className="mt-2 max-h-72 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-slate-400">
                <tr><th className="py-1">Month</th><th>Charge</th><th>Fine</th><th>Due</th><th></th></tr>
              </thead>
              <tbody>
                {invoices.data?.map((i) => (
                  <tr key={i.invoice_id} className="border-t border-slate-100">
                    <td className="py-1.5">{fmtDate(i.period_month)}</td>
                    <td>{fmtPKR(i.charge)}</td>
                    <td className={i.fine > 0 ? 'text-amber-700' : 'text-slate-400'}>{i.fine > 0 ? fmtPKR(i.fine) : '-'}</td>
                    <td className={i.charge - i.allocated > 0 ? 'text-red-600' : ''}>{fmtPKR(i.charge - i.allocated)}</td>
                    <td className="text-right whitespace-nowrap">
                      {i.status !== 'void' && (
                        <button onClick={() => setAsk({ kind: 'fine', invoiceId: i.invoice_id, label: fmtDate(i.period_month) })}
                          className="text-xs text-brand-700 hover:underline">Fine</button>
                      )}
                      {canApprove && i.fine > 0 && (
                        <button onClick={() => setAsk({ kind: 'waive', invoiceId: i.invoice_id, label: fmtDate(i.period_month) })}
                          className="ml-2 text-xs text-slate-500 hover:underline">Waive</button>
                      )}
                    </td>
                  </tr>
                ))}
                {invoices.data?.length === 0 && (
                  <tr><td colSpan={5} className="py-3 text-slate-400">No invoices yet. Generate challans first.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      </div>

      {/* Payment history */}
      <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
        <div className="text-xs uppercase tracking-wide text-slate-500">Payment history</div>
        <table className="mt-2 w-full text-sm">
          <thead className="text-left text-xs text-slate-400">
            <tr><th className="py-1">Receipt</th><th>Date</th><th>Amount</th><th>Method</th><th>Status</th><th>Note</th><th></th></tr>
          </thead>
          <tbody>
            {payments.data?.map((p) => (
              <tr key={p.id} className="border-t border-slate-100">
                <td className="py-1.5">{p.receipt_no != null ? `#${p.receipt_no}` : '-'}</td>
                <td>{fmtDate(p.created_at)}</td>
                <td className={p.amount < 0 ? 'text-red-600' : ''}>{fmtPKR(p.amount)}</td>
                <td>{PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method}</td>
                <td><StatusPill status={p.status} /></td>
                <td className="text-slate-500">{p.reversal_of ? 'Reversal' : p.note}</td>
                <td className="text-right whitespace-nowrap">
                  {p.status === 'verified' && p.amount >= 0 && !p.reversal_of && (
                    <>
                      <button onClick={() => onReprint(p)} className="text-xs text-brand-700 hover:underline">Reprint</button>
                      {canApprove && (
                        <button onClick={() => setAsk({ kind: 'reverse', paymentId: p.id, amount: p.amount, receiptNo: p.receipt_no })}
                          className="ml-2 text-xs text-red-600 hover:underline">Reverse</button>
                      )}
                    </>
                  )}
                </td>
              </tr>
            ))}
            {payments.data?.length === 0 && <tr><td colSpan={7} className="py-3 text-slate-400">No payments yet.</td></tr>}
          </tbody>
        </table>
      </div>

      {ask?.kind === 'fine' && (
        <AskDialog
          title="Apply a late fee"
          intro={<>On {selected?.full_name}&rsquo;s challan for <b>{ask.label}</b>. It is added to what
            the family owes and appears on their statement.</>}
          amount={{ label: 'Amount (Rs)', hint: 'A charge, so it must be positive.' }}
          reason={{ label: 'Reason', required: false, placeholder: 'e.g. ten days late' }}
          confirmLabel="Apply fine"
          busy={fineM.isPending} error={fineM.error ? (fineM.error as Error).message : null}
          onCancel={() => setAsk(null)}
          onSubmit={(v) => fineM.mutate({ invoiceId: (ask as { invoiceId: string }).invoiceId, amount: v.amount, reason: v.reason })}
        />
      )}
      {ask?.kind === 'waive' && (
        <AskDialog
          title="Waive the late fee"
          intro={<>On {selected?.full_name}&rsquo;s challan for <b>{ask.label}</b>. The fee comes off
            what the family owes, and the reason stays on the record.</>}
          reason={{ label: 'Reason for waiving', required: true, minLength: 4,
                    hint: 'Read months later by somebody who was not here.',
                    placeholder: 'e.g. father was in hospital' }}
          confirmLabel="Waive fine"
          busy={waiveM.isPending} error={waiveM.error ? (waiveM.error as Error).message : null}
          onCancel={() => setAsk(null)}
          onSubmit={(v) => waiveM.mutate({ invoiceId: (ask as { invoiceId: string }).invoiceId, reason: v.reason })}
        />
      )}
      {ask?.kind === 'adjust' && (
        <AskDialog
          title="Adjust the balance"
          intro={<>
            {selected?.full_name} owes <b>{fmtPKR(balance.data ?? 0)}</b> today. An adjustment is a
            charge or a credit that is not on any challan: a van fare, a book, a hardship waiver.
            It shows on the family&rsquo;s statement and in the parent portal with the reason you
            write here.
          </>}
          amount={{
            label: 'Amount (Rs)', allowNegative: true,
            hint: 'A positive number ADDS to what they owe. A negative number takes money off, for example -500 to waive Rs 500.',
          }}
          reason={{ label: 'Reason', required: true, minLength: 4,
                    placeholder: 'e.g. van fare for September' }}
          confirmLabel="Adjust balance"
          busy={adjustM.isPending} error={adjustM.error ? (adjustM.error as Error).message : null}
          onCancel={() => setAsk(null)}
          onSubmit={(v) => adjustM.mutate({ amount: v.amount, reason: v.reason })}
        />
      )}
      {ask?.kind === 'reverse' && (
        <AskDialog
          title="Reverse this receipt"
          intro={<>
            Receipt {ask.receiptNo != null ? `#${ask.receiptNo}` : ''} for <b>{fmtPKR(ask.amount)}</b>.
            The receipt is kept and a contra entry is written against it, so the money movement stays
            visible. What the family owes goes back up by this amount.
          </>}
          reason={{ label: 'Reason for reversing', required: true, minLength: 4,
                    placeholder: 'e.g. cheque bounced' }}
          confirmLabel="Reverse receipt" tone="danger"
          busy={reverseM.isPending} error={reverseM.error ? (reverseM.error as Error).message : null}
          onCancel={() => setAsk(null)}
          onSubmit={(v) => reverseM.mutate({ id: (ask as { paymentId: string }).paymentId, reason: v.reason })}
        />
      )}
      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
    </div>
  )
}

function StatusPill({ status }: { status: string }) {
  const tone: Record<string, string> = {
    verified: 'bg-emerald-100 text-emerald-700', pending: 'bg-amber-100 text-amber-700', cancelled: 'bg-slate-200 text-slate-500',
  }
  return <span className={`rounded px-2 py-0.5 text-xs font-medium ${tone[status] ?? 'bg-slate-100 text-slate-600'}`}>{PAYMENT_STATUS_LABELS[status] ?? status}</span>
}

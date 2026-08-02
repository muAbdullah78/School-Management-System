import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  searchStudents, getStudentBalance, getStudentInvoices, getStudentPayments,
  recordPayment, type StudentRow,
} from '@/lib/db'
import { PAYMENT_METHODS, INVOICE_STATUS_LABELS } from '@/lib/constants'
import { fmtPKR, fmtDate } from '@/lib/format'
import { Receipt, type ReceiptData } from '@/components/Receipt'

export function CollectPayment() {
  const [term, setTerm] = useState('')
  const [selected, setSelected] = useState<StudentRow | null>(null)
  const [amount, setAmount] = useState('')
  const [method, setMethod] = useState('cash')
  const [note, setNote] = useState('')
  const [receipt, setReceipt] = useState<ReceiptData | null>(null)
  const qc = useQueryClient()

  const results = useQuery({
    queryKey: ['studentSearch', term],
    queryFn: () => searchStudents(term),
    enabled: term.trim().length >= 2 && !selected,
  })

  const sid = selected?.id
  const balance = useQuery({ queryKey: ['balance', sid], queryFn: () => getStudentBalance(sid!), enabled: !!sid })
  const invoices = useQuery({ queryKey: ['invoices', sid], queryFn: () => getStudentInvoices(sid!), enabled: !!sid })
  const payments = useQuery({ queryKey: ['payments', sid], queryFn: () => getStudentPayments(sid!), enabled: !!sid })

  const pay = useMutation({
    mutationFn: () => recordPayment(sid!, Number(amount), method, note || undefined),
    onSuccess: async (res) => {
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
      qc.invalidateQueries({ queryKey: ['balance', sid] })
      qc.invalidateQueries({ queryKey: ['invoices', sid] })
      qc.invalidateQueries({ queryKey: ['payments', sid] })
    },
  })

  function reset() {
    setSelected(null); setTerm(''); setAmount(''); setNote('')
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
            <button key={s.id} onClick={() => setSelected(s)} className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50">
              <span className="font-medium text-slate-800">{s.full_name}</span>
              {s.father_name && <span className="text-slate-500"> · {s.father_name}</span>}
              {s.gr_no && <span className="text-slate-400"> · {s.gr_no}</span>}
            </button>
          ))}
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-base font-semibold text-slate-800">{selected.full_name}</div>
          <div className="text-xs text-slate-500">{selected.father_name} · {selected.gr_no ?? 'no GR'}</div>
        </div>
        <button onClick={reset} className="text-sm text-brand-700 hover:underline">Change student</button>
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
            {pay.isError && <p className="text-sm text-red-600">{(pay.error as Error).message}</p>}
            <button type="submit" disabled={pay.isPending || !(Number(amount) > 0)}
              className="w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {pay.isPending ? 'Recording…' : 'Record payment & print receipt'}
            </button>
          </form>
        </div>

        {/* Open invoices */}
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Invoices</div>
          <div className="mt-2 max-h-72 overflow-y-auto">
            <table className="w-full text-sm">
              <thead className="text-left text-xs text-slate-400">
                <tr><th className="py-1">Month</th><th>Charge</th><th>Paid</th><th>Due</th><th>Status</th></tr>
              </thead>
              <tbody>
                {invoices.data?.map((i) => (
                  <tr key={i.invoice_id} className="border-t border-slate-100">
                    <td className="py-1.5">{fmtDate(i.period_month)}</td>
                    <td>{fmtPKR(i.charge)}</td>
                    <td>{fmtPKR(i.allocated)}</td>
                    <td className={i.charge - i.allocated > 0 ? 'text-red-600' : ''}>{fmtPKR(i.charge - i.allocated)}</td>
                    <td>{INVOICE_STATUS_LABELS[i.status] ?? i.status}</td>
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
            <tr><th className="py-1">Receipt</th><th>Date</th><th>Amount</th><th>Method</th><th>Note</th></tr>
          </thead>
          <tbody>
            {payments.data?.map((p) => (
              <tr key={p.id} className="border-t border-slate-100">
                <td className="py-1.5">#{p.receipt_no}</td>
                <td>{fmtDate(p.created_at)}</td>
                <td className={p.amount < 0 ? 'text-red-600' : ''}>{fmtPKR(p.amount)}</td>
                <td>{PAYMENT_METHODS.find((m) => m.value === p.method)?.label ?? p.method}</td>
                <td className="text-slate-500">{p.reversal_of ? 'Reversal' : p.note}</td>
              </tr>
            ))}
            {payments.data?.length === 0 && <tr><td colSpan={5} className="py-3 text-slate-400">No payments yet.</td></tr>}
          </tbody>
        </table>
      </div>

      {receipt && <Receipt data={receipt} onClose={() => setReceipt(null)} />}
    </div>
  )
}

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  creditNote, platformInvoice, platformLedger, setInvoiceTax, voidInvoice,
  type InvoiceDocument, type LedgerEntry, type PlatformSchool, type PlatformSettings,
  platformSettings,
} from '@/lib/platform'
import { InvoiceDoc } from '@/components/InvoiceDoc'
import { formatPkr } from '@/lib/licence'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * One school's statement, and the three things you can do to a document on it.
 *
 * Before 0077 this table had no document numbers, so a line could not be pointed
 * at — "the Rs 38,000 one" was the only way to name it, and two renewals of the
 * same plan in a year made that ambiguous. It also had no way to correct
 * anything: a wrong charge sat in the books forever and every total was wrong
 * with it.
 *
 * VOID AND CREDIT ARE NOT THE SAME THING, and the buttons say which is which:
 *
 *   Void        the document should never have existed — wrong school, wrong
 *               plan, raised twice by a double click. Excluded from every total.
 *               Refused once a payment or a credit note is attached, because
 *               that is exactly the case a credit note exists for.
 *   Credit      the document was RIGHT and part of it is being given back — a
 *               school that paid for twelve months, used four and left. Voiding
 *               that would erase a real sale and unbalance the books against a
 *               payment genuinely received.
 */
export function LedgerDialog({ school, onClose }: {
  school: PlatformSchool; onClose: () => void
}) {
  const q = useQuery({
    queryKey: ['platformLedger', school.school_id],
    queryFn: () => platformLedger(school.school_id),
  })
  const settings = useQuery({ queryKey: ['platformSettings'], queryFn: platformSettings })
  const [printing, setPrinting] = useState<string | null>(null)
  const [acting, setActing] = useState<{ e: LedgerEntry; mode: Mode } | null>(null)

  // A running balance, computed here rather than stored, so it can never
  // disagree with the rows above it.
  let bal = 0

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4">
      <div className="w-full max-w-4xl rounded-lg bg-white p-5 shadow-lg">
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

        {settings.data && settings.data.missing.length > 0 && (
          <p className="mt-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
            Invoices will print without {settings.data.missing.map((m) => m.replace(/_/g, ' ')).join(', ')}.
            Fill it in under the Our billing tab before sending anything.
          </p>
        )}

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
                  <th className="w-24 px-2 py-2">Date</th>
                  <th className="w-24 px-2 py-2">Number</th>
                  <th className="px-2 py-2">What</th>
                  <th className="w-24 px-2 py-2 text-right">Charged</th>
                  <th className="w-24 px-2 py-2 text-right">Paid</th>
                  <th className="w-24 px-2 py-2 text-right">Balance</th>
                  <th className="w-40 px-2 py-2"></th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {q.data.map((e) => {
                  bal += Number(e.charged ?? 0) - Number(e.paid ?? 0)
                  const isDoc = e.kind !== 'payment'
                  return (
                    <tr key={e.entry_id} className={e.voided ? 'text-slate-400' : ''}>
                      <td className="px-2 py-2 text-slate-500">{e.entry_date}</td>
                      <td className="px-2 py-2">
                        <span className={e.voided ? 'line-through' : 'font-medium text-slate-700'}>
                          {e.doc_no ?? ''}
                        </span>
                      </td>
                      <td className="px-2 py-2 text-slate-700">
                        {e.description}
                        {e.reference && <span className="text-slate-400"> · {e.reference}</span>}
                        {e.note && <div className="text-xs text-slate-500">{e.note}</div>}
                      </td>
                      <td className={`px-2 py-2 text-right ${
                        Number(e.charged ?? 0) < 0 ? 'text-emerald-700' : 'text-slate-700'}`}>
                        {e.charged ? formatPkr(Number(e.charged)) : ''}
                      </td>
                      <td className="px-2 py-2 text-right text-emerald-700">
                        {e.paid ? formatPkr(Number(e.paid)) : ''}
                      </td>
                      <td className="px-2 py-2 text-right font-medium text-slate-800">
                        {formatPkr(bal)}
                      </td>
                      <td className="px-2 py-2 text-right text-xs">
                        {isDoc && (
                          <div className="flex flex-wrap justify-end gap-2">
                            <button onClick={() => setPrinting(e.entry_id)}
                              className="text-brand-700 hover:underline">Print</button>
                            {!e.voided && (
                              <>
                                <button onClick={() => setActing({ e, mode: 'void' })}
                                  className="text-slate-500 hover:underline">Void</button>
                                {e.kind === 'invoice' && (
                                  <>
                                    <button onClick={() => setActing({ e, mode: 'credit' })}
                                      className="text-slate-500 hover:underline">Credit</button>
                                    <button onClick={() => setActing({ e, mode: 'tax' })}
                                      className="text-slate-500 hover:underline">Tax</button>
                                  </>
                                )}
                              </>
                            )}
                          </div>
                        )}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {printing && <PrintDialog invoiceId={printing} onClose={() => setPrinting(null)} />}
      {acting && (
        <DocActionDialog entry={acting.e} mode={acting.mode}
          settings={settings.data} onClose={() => setActing(null)} />
      )}
    </div>
  )
}

type Mode = 'void' | 'credit' | 'tax'

function PrintDialog({ invoiceId, onClose }: { invoiceId: string; onClose: () => void }) {
  const q = useQuery({
    queryKey: ['platformInvoice', invoiceId],
    queryFn: () => platformInvoice(invoiceId),
  })
  return (
    <div className="fixed inset-0 z-[60] overflow-y-auto bg-black/50 p-4">
      <div className="mx-auto max-w-3xl rounded-lg bg-white p-3 shadow-lg">
        <div className="flex items-center justify-between gap-2 print:hidden">
          <button onClick={() => window.print()}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
            Print
          </button>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        {q.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
        {q.error && <p className="p-4 text-sm text-red-600">{(q.error as Error).message}</p>}
        {q.data && <InvoiceDoc d={q.data as InvoiceDocument} />}
      </div>
    </div>
  )
}

function DocActionDialog({ entry, mode, settings, onClose }: {
  entry: LedgerEntry; mode: Mode; settings?: PlatformSettings; onClose: () => void
}) {
  const qc = useQueryClient()
  const charged = Math.abs(Number(entry.charged ?? 0))
  const [reason, setReason] = useState('')
  const [amount, setAmount] = useState(String(charged))
  const [pct, setPct] = useState(String(settings?.default_withholding_pct ?? 0))
  const [err, setErr] = useState<string | null>(null)
  const [warn, setWarn] = useState<string | null>(null)

  const act = useMutation({
    mutationFn: async () => {
      if (mode === 'void') {
        const r = await voidInvoice(entry.entry_id, reason)
        return r.warning
      }
      if (mode === 'credit') {
        await creditNote({ invoiceId: entry.entry_id, amount: Number(amount), reason })
        return null
      }
      await setInvoiceTax(entry.entry_id, Number(pct))
      return null
    },
    onSuccess: (w) => {
      void qc.invalidateQueries({ queryKey: ['platformLedger'] })
      void qc.invalidateQueries({ queryKey: ['platformSchools'] })
      void qc.invalidateQueries({ queryKey: ['platformRevenue'] })
      void qc.invalidateQueries({ queryKey: ['schoolDetail'] })
      // The licence warning is the one message that must NOT be dismissed by
      // closing the dialog: voiding the charge for a year the school still holds
      // is a half-finished correction, and it will be forgotten otherwise.
      if (w) { setWarn(w); setErr(null) } else { onClose() }
    },
    onError: (e) => setErr((e as Error).message),
  })

  if (warn) {
    return (
      <Shell title="Voided — one thing is left to decide" onClose={onClose}>
        <p className="text-sm text-amber-900">{warn}</p>
        <button onClick={onClose}
          className="mt-4 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700">
          Understood
        </button>
      </Shell>
    )
  }

  return (
    <Shell
      title={mode === 'void' ? `Void ${entry.doc_no ?? 'this document'}`
        : mode === 'credit' ? `Credit against ${entry.doc_no ?? 'this invoice'}`
        : `Tax on ${entry.doc_no ?? 'this invoice'}`}
      onClose={onClose}>
      {mode === 'void' && (
        <p className="text-xs text-slate-500">
          For a document that should never have existed. It stays on the statement —
          deleting history is how a business loses an audit — but it stops adding up to
          anything. If the invoice was right and you are giving part of it back, use
          Credit instead.
        </p>
      )}
      {mode === 'credit' && (
        <p className="text-xs text-slate-500">
          For an invoice that was correct where part of it is no longer due — a school
          that paid for a year, used four months and left. It gets its own document
          number and reduces the balance. At most {formatPkr(charged)} can be credited.
        </p>
      )}
      {mode === 'tax' && (
        <p className="text-xs text-slate-500">
          Provincial sales tax on services — PRA, SRB, KPRA or BRA depending on where
          you are registered. Left at zero unless you are registered to charge it: a
          tax printed confidently on an invoice from an unregistered business invents a
          liability. Refused once anything has been paid against this invoice.
        </p>
      )}

      {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

      <div className="mt-3 space-y-3">
        {mode === 'credit' && (
          <label className="block">
            <span className="text-xs font-medium text-slate-600">How much to credit</span>
            <input type="number" step="0.01" min="0.01" max={charged} className={FIELD}
              value={amount} onChange={(e) => setAmount(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              Any tax on the invoice is credited in proportion.
            </span>
          </label>
        )}
        {mode === 'tax' && (
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Rate (%)</span>
            <input type="number" step="0.01" min="0" max="100" className={FIELD}
              value={pct} onChange={(e) => setPct(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              {Number(pct) > 0
                ? `Adds ${formatPkr(charged * Number(pct) / 100)} to this invoice.`
                : 'Zero removes the tax line entirely.'}
            </span>
          </label>
        )}
        {mode !== 'tax' && (
          <label className="block">
            <span className="text-xs font-medium text-slate-600">
              Reason — printed on the document
            </span>
            <textarea rows={2} className={FIELD} value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder={mode === 'void'
                ? 'e.g. raised twice by mistake'
                : 'e.g. left in March, four months unused'} />
            <span className="mt-0.5 block text-xs text-slate-400">
              The database refuses this without one. A correction nobody wrote a reason
              for is an unexplained hole in a set of books.
            </span>
          </label>
        )}
      </div>

      <div className="mt-4 flex gap-2">
        <button onClick={() => act.mutate()}
          disabled={act.isPending || (mode !== 'tax' && reason.trim().length === 0)}
          className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {act.isPending ? 'Saving…'
            : mode === 'void' ? 'Void it'
            : mode === 'credit' ? 'Raise the credit note'
            : 'Set the tax'}
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
    <div className="fixed inset-0 z-[60] flex items-center justify-center overflow-y-auto bg-black/50 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-4 shadow-lg">
        <div className="flex items-start justify-between gap-2">
          <h3 className="text-sm font-semibold text-slate-800">{title}</h3>
          <button onClick={onClose} className="text-sm text-slate-500 hover:underline">Close</button>
        </div>
        <div className="mt-2">{children}</div>
      </div>
    </div>
  )
}

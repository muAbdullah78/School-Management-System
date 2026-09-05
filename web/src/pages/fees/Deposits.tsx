/**
 * Refundable deposits: what the school is holding, and giving it back.
 *
 * A security deposit is the one kind of money a school takes that is NOT its
 * own. Before migration 0060 it counted as profit: Rs 5,000 held made the
 * proprietor's "what did we keep" figure Rs 5,000 too high, and at 200 pupils
 * that is a million rupees somebody might pay a salary out of. There was also no
 * way at all to record giving it back.
 *
 * Two things shape this screen:
 *
 *  * The list includes pupils who have LEFT and not been refunded. That is the
 *    whole point. It is the money still owed. A list that dropped them would
 *    make the liability shrink the moment a child left.
 *  * Refunding NETS the arrears first, because that is what a clerk says at the
 *    counter: "you owe 3,000, your deposit is 5,000, here is 2,000 back." The
 *    netting is recorded as an adjustment, so no cash report gains money that
 *    never crossed the counter.
 *
 * See docs/DEPOSITS-DESIGN.md.
 */
import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listDepositsHeld, refundDeposit, chargeDeposit, listFeeHeads, searchStudents,
  getStudentBalance,
  type DepositHeldRow, type DepositRefundResult, type StudentRow,
} from '@/lib/db'
import { fmtPKR, fmtDate } from '@/lib/format'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { DataTable, type Column } from '@/components/DataTable'

const FIELD = 'mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

export function Deposits() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  // Money leaving the school is an approval, not a clerical act. The database
  // enforces the same two roles; this only stops offering a button that refuses.
  const mayRefund = mayWrite && ['owner', 'principal'].includes(profile?.role ?? '')

  const held = useQuery({ queryKey: ['depositsHeld'], queryFn: listDepositsHeld })
  const heads = useQuery({ queryKey: ['feeHeads'], queryFn: listFeeHeads })
  const refundable = (heads.data ?? []).filter((h) => h.is_refundable)

  const [refunding, setRefunding] = useState<DepositHeldRow | null>(null)
  const [charging, setCharging] = useState(false)
  const [done, setDone] = useState<DepositRefundResult | null>(null)

  const rows = held.data ?? []
  const total = rows.reduce((s, r) => s + r.held, 0)
  const leavers = rows.filter((r) => r.status !== 'active')

  const columns: Column<DepositHeldRow>[] = [
    {
      key: 'full_name', header: 'Student', sortable: true, value: (r) => r.full_name,
      render: (r) => (
        <div>
          <div className="font-medium text-slate-800">{r.full_name}</div>
          <div className="text-xs text-slate-400">
            {r.gr_no ?? '-'}
            {r.father_name ? ` · ${r.father_name}` : ''}
          </div>
        </div>
      ),
    },
    {
      key: 'class_name', header: 'Class', value: (r) => r.class_name,
      render: (r) => <span className="text-slate-600">{r.class_name ?? '-'}</span>,
    },
    {
      key: 'status', header: 'On roll', value: (r) => r.status,
      render: (r) => (
        r.status === 'active'
          ? <span className="text-money-700">Yes</span>
          : (
            // The row that matters most: a child who has gone and whose money
            // the school still has.
            <span className="text-amber-700">
              {r.status.replace('_', ' ')}
              {r.left_on ? ` · ${fmtDate(r.left_on)}` : ''}
            </span>
          )
      ),
    },
    {
      key: 'collected', header: 'Collected', align: 'right', sortable: true,
      value: (r) => r.collected, secondary: true,
      render: (r) => <span className="text-slate-500">{fmtPKR(r.collected)}</span>,
    },
    {
      key: 'refunded', header: 'Refunded', align: 'right', sortable: true,
      value: (r) => r.refunded, secondary: true,
      render: (r) => <span className="text-slate-500">{r.refunded ? fmtPKR(r.refunded) : '-'}</span>,
    },
    {
      key: 'held', header: 'Held', align: 'right', sortable: true, value: (r) => r.held,
      render: (r) => <span className="font-semibold text-slate-800">{fmtPKR(r.held)}</span>,
    },
    {
      key: 'act', header: '', align: 'right', value: () => null,
      render: (r) => (
        mayRefund
          ? (
            <button onClick={() => { setRefunding(r); setDone(null) }}
              className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">
              Refund
            </button>
          )
          : null
      ),
    },
  ]

  return (
    <div>
      {!mayWrite && <ObserverNotice what="deposits the school is holding" />}

      {refundable.length === 0 && (
        <div className="mb-4 rounded-lg border border-slate-200 bg-slate-50 p-3 text-sm text-slate-600">
          No fee head is marked <strong>refundable</strong> yet, so the school is holding
          nothing. Mark a head refundable under <strong>Settings → Fee structure</strong>:
          typically &ldquo;Security Deposit&rdquo;. Until then nothing on this screen changes,
          and no figure anywhere else changes either.
        </div>
      )}

      <div className="mb-4 grid gap-3 sm:grid-cols-3">
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Total held</div>
          <div className="mt-1 text-2xl font-semibold text-slate-800">{fmtPKR(total)}</div>
          <div className="mt-1 text-xs text-slate-500">
            A liability, not income. It is excluded from profit and shown on the balance sheet.
          </div>
        </div>
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Families</div>
          <div className="mt-1 text-2xl font-semibold text-slate-800">{rows.length}</div>
        </div>
        <div className="rounded-lg bg-white p-4 shadow-sm ring-1 ring-slate-200">
          <div className="text-xs uppercase tracking-wide text-slate-500">Already left</div>
          <div className={`mt-1 text-2xl font-semibold ${leavers.length ? 'text-amber-700' : 'text-slate-800'}`}>
            {leavers.length}
          </div>
          <div className="mt-1 text-xs text-slate-500">
            {leavers.length
              ? 'Money still owed to families who have gone: refund or net it off.'
              : 'Nobody who has left is still owed a deposit.'}
          </div>
        </div>
      </div>

      {mayWrite && refundable.length > 0 && (
        <div className="mb-3">
          <button onClick={() => setCharging(true)}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
            + Charge a deposit
          </button>
        </div>
      )}

      {done && (
        <div className="mb-4 rounded-lg border border-money-200 bg-money-50 px-4 py-3 text-sm text-money-800">
          <div className="font-medium">
            {done.student_name}: {fmtPKR(done.amount)} refunded.
          </div>
          <div className="mt-0.5">
            {done.applied_to_dues > 0
              ? <>{fmtPKR(done.applied_to_dues)} was applied to what they owed, and <strong>{fmtPKR(done.paid_out)}</strong> is to be handed back.</>
              : <><strong>{fmtPKR(done.paid_out)}</strong> is to be handed back. They owed nothing.</>}
            {done.still_held > 0 && ` ${fmtPKR(done.still_held)} is still held.`}
          </div>
          {done.was_enrolled && (
            <div className="mt-1 text-xs">
              This pupil is still enrolled. The refund is recorded as an early one.
            </div>
          )}
        </div>
      )}

      <DataTable
        rows={rows}
        columns={columns}
        rowKey={(r) => r.student_id}
        loading={held.isLoading}
        error={held.isError ? (held.error as Error).message : null}
        emptyTitle="No deposits held"
        emptyMessage="Nothing has been collected against a refundable fee head yet."
        exportName="deposits-held"
        printId="report"
      />

      {refunding && (
        <RefundDialog
          row={refunding}
          onClose={() => setRefunding(null)}
          onDone={(r) => {
            setRefunding(null); setDone(r)
            qc.invalidateQueries({ queryKey: ['depositsHeld'] })
            qc.invalidateQueries({ queryKey: ['studentBalance'] })
            qc.invalidateQueries({ queryKey: ['financeSummary'] })
          }}
        />
      )}
      {charging && (
        <ChargeDialog
          heads={refundable}
          onClose={() => setCharging(false)}
          onDone={() => {
            setCharging(false)
            qc.invalidateQueries({ queryKey: ['depositsHeld'] })
          }}
        />
      )}
    </div>
  )
}

function RefundDialog({ row, onClose, onDone }: {
  row: DepositHeldRow
  onClose: () => void
  onDone: (r: DepositRefundResult) => void
}) {
  const [amount, setAmount] = useState(String(row.held))
  const [net, setNet] = useState(true)
  const [method, setMethod] = useState('cash')
  const [reason, setReason] = useState('')

  // Read live rather than trusting the list: the arrears may have moved since
  // the page loaded, and the figure shown next to "will be applied to dues" has
  // to be the one the server will actually use.
  const bal = useQuery({
    queryKey: ['studentBalance', row.student_id],
    queryFn: () => getStudentBalance(row.student_id),
  })
  const owed = Math.max(0, bal.data ?? 0)
  const amt = Number(amount) || 0
  const willNet = net ? Math.min(owed, amt) : 0
  const willPay = amt - willNet
  const tooMuch = amt > row.held

  const m = useMutation({
    mutationFn: () => refundDeposit({
      studentId: row.student_id, amount: amt, netAgainstDues: net,
      method, reason: reason.trim() || null,
    }),
    onSuccess: onDone,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <div className="text-base font-semibold text-slate-800">
          Refund {row.full_name}&rsquo;s deposit
        </div>
        <div className="mt-0.5 text-sm text-slate-500">
          {fmtPKR(row.held)} held
          {row.status !== 'active' ? ` · left ${row.left_on ? fmtDate(row.left_on) : ''}` : ' · still enrolled'}
        </div>

        {row.status === 'active' && (
          <div className="mt-3 rounded border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-800">
            This pupil has not left. An early refund is allowed and will be recorded
            as such, so it can be told apart from an ordinary leaving refund.
          </div>
        )}

        <label className="mt-4 block">
          <span className="text-sm text-slate-600">Amount to refund</span>
          <input type="number" min="0" max={row.held} value={amount}
            onChange={(e) => setAmount(e.target.value)} className={FIELD} />
        </label>
        {tooMuch && (
          <p className="mt-1 text-xs text-red-600">
            Only {fmtPKR(row.held)} is held. The refund cannot be more than that.
          </p>
        )}

        <label className="mt-3 flex items-start gap-2 text-sm">
          <input type="checkbox" checked={net} onChange={(e) => setNet(e.target.checked)}
            className="mt-0.5 h-4 w-4" />
          <span>
            <span className="text-slate-700">Settle what they owe first</span>
            <span className="block text-xs text-slate-500">
              {owed > 0
                ? `They owe ${fmtPKR(owed)}. Recorded as an adjustment, so no cash report gains money that did not move.`
                : 'They owe nothing, so this changes nothing.'}
            </span>
          </span>
        </label>

        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          <label className="block">
            <span className="text-sm text-slate-600">Paid out by</span>
            <select value={method} onChange={(e) => setMethod(e.target.value)} className={FIELD}>
              <option value="cash">Cash</option>
              <option value="bank_transfer">Bank transfer</option>
              <option value="other">Other</option>
            </select>
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">Reason (optional)</span>
            <input value={reason} onChange={(e) => setReason(e.target.value)}
              className={FIELD} placeholder="e.g. left the school" />
          </label>
        </div>

        <div className="mt-4 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm">
          <div className="flex justify-between">
            <span className="text-slate-600">Applied to what they owe</span>
            <span className="font-medium text-slate-800">{fmtPKR(willNet)}</span>
          </div>
          <div className="mt-1 flex justify-between">
            <span className="text-slate-600">Handed back</span>
            <span className="font-semibold text-slate-900">{fmtPKR(Math.max(0, willPay))}</span>
          </div>
        </div>

        {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}

        <div className="mt-4 flex gap-2">
          <button onClick={() => m.mutate()} disabled={m.isPending || tooMuch || amt <= 0}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {m.isPending ? 'Recording…' : 'Record refund'}
          </button>
          <button onClick={onClose}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

function ChargeDialog({ heads, onClose, onDone }: {
  heads: { id: string; name: string }[]
  onClose: () => void
  onDone: () => void
}) {
  const [term, setTerm] = useState('')
  const [student, setStudent] = useState<StudentRow | null>(null)
  const [headId, setHeadId] = useState(heads[0]?.id ?? '')
  const [amount, setAmount] = useState('')

  const results = useQuery({
    queryKey: ['depositStudentSearch', term],
    queryFn: () => searchStudents(term),
    enabled: term.trim().length >= 2 && !student,
  })

  const m = useMutation({
    mutationFn: () => chargeDeposit(student!.id, headId, Number(amount)),
    onSuccess: onDone,
  })

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-lg">
        <div className="text-base font-semibold text-slate-800">Charge a deposit</div>
        <p className="mt-1 text-xs text-slate-500">
          It is billed on its <strong>own challan</strong>, separate from the monthly fee.
          That is deliberate: a payment is recorded against a challan, so mixing the two
          would make &ldquo;how much of this was the deposit&rdquo; unanswerable.
        </p>

        {!student ? (
          <label className="mt-4 block">
            <span className="text-sm text-slate-600">Search student by name or GR number</span>
            <input autoFocus value={term} onChange={(e) => setTerm(e.target.value)}
              className={FIELD} placeholder="e.g. Ahmed or GR-0001" />
            {(results.data ?? []).length > 0 && (
              <div className="mt-2 max-h-48 overflow-y-auto rounded border border-slate-200">
                {results.data!.map((s) => (
                  <button key={s.id} onClick={() => setStudent(s)}
                    className="block w-full px-3 py-2 text-left text-sm hover:bg-slate-50">
                    {s.full_name}
                    <span className="text-slate-400">
                      {s.gr_no ? ` · ${s.gr_no}` : ''}{s.father_name ? ` · ${s.father_name}` : ''}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </label>
        ) : (
          <>
            <div className="mt-4 flex items-center justify-between rounded border border-slate-200 px-3 py-2">
              <span className="text-sm text-slate-800">
                {student.full_name}
                <span className="text-slate-400">{student.gr_no ? ` · ${student.gr_no}` : ''}</span>
              </span>
              <button onClick={() => { setStudent(null); setTerm('') }}
                className="text-xs text-brand-700 hover:underline">Change</button>
            </div>
            <div className="mt-3 grid gap-3 sm:grid-cols-2">
              <label className="block">
                <span className="text-sm text-slate-600">Fee head</span>
                <select value={headId} onChange={(e) => setHeadId(e.target.value)} className={FIELD}>
                  {heads.map((h) => <option key={h.id} value={h.id}>{h.name}</option>)}
                </select>
              </label>
              <label className="block">
                <span className="text-sm text-slate-600">Amount</span>
                <input type="number" min="1" value={amount}
                  onChange={(e) => setAmount(e.target.value)} className={FIELD} />
              </label>
            </div>
          </>
        )}

        {m.isError && <p className="mt-2 text-sm text-red-600">{(m.error as Error).message}</p>}

        <div className="mt-4 flex gap-2">
          <button onClick={() => m.mutate()}
            disabled={!student || !headId || !(Number(amount) > 0) || m.isPending}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {m.isPending ? 'Charging…' : 'Charge deposit'}
          </button>
          <button onClick={onClose}
            className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

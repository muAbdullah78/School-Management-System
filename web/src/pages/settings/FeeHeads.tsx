import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listFeeHeadsFull, upsertFeeHead, setFeeHeadActive, type FeeHeadRow } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none'

// The fee_head_type enum, with the words a Pakistani school office uses.
const TYPES: { value: string; label: string; recurring: boolean }[] = [
  { value: 'monthly', label: 'Monthly (tuition, and anything billed every month)', recurring: true },
  { value: 'admission', label: 'Admission: charged once when a child joins', recurring: false },
  { value: 'annual', label: 'Annual: charged once a year', recurring: false },
  { value: 'exam', label: 'Exam fee', recurring: false },
  { value: 'security_deposit', label: 'Security deposit: refundable', recurring: false },
  { value: 'transport', label: 'Transport', recurring: true },
  { value: 'misc', label: 'Other', recurring: false },
]

/**
 * Managing what the school charges for.
 *
 * This screen did not exist. `fee_heads` has had a write policy since the first
 * migration, but nothing in the app ever inserted one, so a new school had no
 * 'Tuition' to put an amount against, Settings → Fee Structure showed an empty
 * list with a Save button, and the school could never bill a monthly fee. It is
 * the first thing a school must do and it was the one thing it could not.
 */
export function FeeHeads() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
    && ['owner', 'principal', 'admin_clerk'].includes(profile?.role ?? '')
  const [showInactive, setShowInactive] = useState(false)
  const [editing, setEditing] = useState<FeeHeadRow | null>(null)
  const [adding, setAdding] = useState(false)

  const heads = useQuery({
    queryKey: ['feeHeadsFull', showInactive],
    queryFn: () => listFeeHeadsFull(showInactive),
  })

  const toggle = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => setFeeHeadActive(v.id, v.active),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['feeHeadsFull'] })
      qc.invalidateQueries({ queryKey: ['feeStructure'] })
      qc.invalidateQueries({ queryKey: ['feeHeads'] })
    },
  })

  return (
    <div className="max-w-3xl space-y-4">
      <p className="text-sm text-slate-600">
        A fee head is a thing the school charges for: Tuition, Admission Fee, Exam Fee, Security
        Deposit. Create them here, then set the amount per class under{' '}
        <span className="font-medium">Fee Structure</span>.
      </p>

      {!mayWrite && <ObserverNotice what="the fee heads this school charges" />}

      {heads.data?.length === 0 && !heads.isLoading && (
        <div className="rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          <div className="font-medium">Nothing is set up yet.</div>
          <div className="mt-1">
            Almost every school starts with <span className="font-medium">Tuition</span> (monthly),
            an <span className="font-medium">Admission Fee</span> (once, when a child joins), and an{' '}
            <span className="font-medium">Exam Fee</span>. Add those three and you can bill.
          </div>
        </div>
      )}

      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr>
              <th className="px-3 py-2">Fee head</th>
              <th className="px-3 py-2 w-48">Charged</th>
              <th className="px-3 py-2 w-20">Order</th>
              <th className="px-3 py-2 w-44"></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {heads.isLoading && <tr><td colSpan={4} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {heads.data?.map((h) => (
              <tr key={h.id} className={h.active ? '' : 'opacity-60'}>
                <td className="px-3 py-2 text-slate-800">
                  {h.name}
                  {h.is_refundable && (
                    <span className="ml-2 rounded bg-sky-100 px-1.5 py-0.5 text-xs text-sky-800">refundable</span>
                  )}
                  {!h.active && (
                    <span className="ml-2 rounded bg-slate-200 px-1.5 py-0.5 text-xs text-slate-600">off</span>
                  )}
                </td>
                <td className="px-3 py-2 text-slate-600">
                  {h.is_recurring ? 'Every month' : 'Once'}
                  <span className="ml-1 text-slate-400">· {h.type.replace('_', ' ')}</span>
                </td>
                <td className="px-3 py-2 text-slate-500">{h.sort_order}</td>
                <td className="px-3 py-2 text-right whitespace-nowrap">
                  {mayWrite && (
                    <>
                      <button onClick={() => setEditing(h)}
                        className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50">
                        Edit
                      </button>
                      <button onClick={() => toggle.mutate({ id: h.id, active: !h.active })}
                        disabled={toggle.isPending}
                        className="ml-1 rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
                        title={h.in_use
                          ? 'This head has already been billed, so it cannot be deleted: switching it off stops it being charged and keeps past challans readable.'
                          : 'Stop charging this head'}>
                        {h.active ? 'Switch off' : 'Switch on'}
                      </button>
                    </>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {toggle.isError && <p className="text-sm text-red-600">{(toggle.error as Error).message}</p>}

      <div className="flex items-center justify-between">
        <label className="flex items-center gap-2 text-xs text-slate-600">
          <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
          Show ones that are switched off
        </label>
        {mayWrite && (
          <button onClick={() => setAdding(true)}
            className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700">
            Add a fee head
          </button>
        )}
      </div>

      <p className="text-xs text-slate-500">
        A fee head that has already been billed cannot be deleted. An issued challan names it, and
        removing it would change what a parent was charged for. Switch it off instead: nothing new is
        charged against it and every past challan still reads correctly.
      </p>

      {(adding || editing) && (
        <FeeHeadDialog
          head={editing}
          onClose={() => { setAdding(false); setEditing(null) }}
          onSaved={() => {
            setAdding(false); setEditing(null)
            qc.invalidateQueries({ queryKey: ['feeHeadsFull'] })
            qc.invalidateQueries({ queryKey: ['feeStructure'] })
            qc.invalidateQueries({ queryKey: ['feeHeads'] })
          }}
        />
      )}
    </div>
  )
}

function FeeHeadDialog({
  head, onClose, onSaved,
}: { head: FeeHeadRow | null; onClose: () => void; onSaved: () => void }) {
  const [name, setName] = useState(head?.name ?? '')
  const [type, setType] = useState(head?.type ?? 'monthly')
  const [recurring, setRecurring] = useState(head?.is_recurring ?? true)
  const [refundable, setRefundable] = useState(head?.is_refundable ?? false)
  const [order, setOrder] = useState(String(head?.sort_order ?? 0))

  const save = useMutation({
    mutationFn: () => upsertFeeHead({
      id: head?.id ?? null, name, type,
      is_recurring: recurring, is_refundable: refundable,
      sort_order: Number(order) || 0,
    }),
    onSuccess: onSaved,
  })

  // Picking a type sets the sensible default for how often it is charged, and
  // marks a security deposit refundable. The school should not have to know
  // that a deposit is the one head 0060 treats as a liability rather than income.
  function pickType(v: string) {
    setType(v)
    const t = TYPES.find((x) => x.value === v)
    if (t) setRecurring(t.recurring)
    if (v === 'security_deposit') { setRefundable(true); setRecurring(false) }
    else setRefundable(false)
  }

  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-black/40 p-4 sm:items-center">
      <div className="w-full max-w-lg rounded-lg bg-white p-5 shadow-lg">
        <h2 className="text-base font-semibold text-slate-800">
          {head ? `Edit ${head.name}` : 'Add a fee head'}
        </h2>
        <div className="mt-3 space-y-3">
          <label className="block">
            <span className="text-sm text-slate-600">Name</span>
            <input autoFocus value={name} onChange={(e) => setName(e.target.value)}
              placeholder="e.g. Tuition" className={`${FIELD} mt-1 w-full`} />
          </label>
          <label className="block">
            <span className="text-sm text-slate-600">What kind of charge is it?</span>
            <select value={type} onChange={(e) => pickType(e.target.value)} className={`${FIELD} mt-1 w-full`}>
              {TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </label>
          <div className="flex flex-wrap gap-4">
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" checked={recurring} disabled={refundable}
                onChange={(e) => setRecurring(e.target.checked)} />
              Charge it every month
            </label>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              <input type="checkbox" checked={refundable}
                onChange={(e) => { setRefundable(e.target.checked); if (e.target.checked) setRecurring(false) }} />
              Refundable (the school gives it back)
            </label>
            <label className="flex items-center gap-2 text-sm text-slate-700">
              Order
              <input value={order} onChange={(e) => setOrder(e.target.value)}
                inputMode="numeric" className={`${FIELD} w-16`} />
            </label>
          </div>
          {refundable && (
            <p className="rounded border border-sky-200 bg-sky-50 px-3 py-2 text-xs text-sky-900">
              A refundable head is money the school <span className="font-medium">holds</span>, not
              income. It appears as a liability on the balance sheet and can be refunded or netted
              against arrears when the child leaves. It cannot also be charged monthly.
            </p>
          )}
          {save.isError && <p className="text-sm text-red-600">{(save.error as Error).message}</p>}
        </div>
        <div className="mt-4 flex gap-2">
          <button onClick={() => save.mutate()} disabled={save.isPending || !name.trim()}
            className="flex-1 rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {save.isPending ? 'Saving…' : 'Save'}
          </button>
          <button onClick={onClose} className="flex-1 rounded border border-slate-300 px-3 py-2 text-sm hover:bg-slate-50">
            Cancel
          </button>
        </div>
      </div>
    </div>
  )
}

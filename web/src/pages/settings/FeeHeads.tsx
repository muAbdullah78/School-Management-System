import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listFeeHeadsFull, upsertFeeHead, setFeeHeadActive, type FeeHeadRow } from '@/lib/db'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'
import { ObserverNotice } from '@/components/ObserverNotice'
import { Button } from '@/components/ui'

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
        <div className="rounded-2xl border border-due-200 bg-due-50 p-4 text-sm text-due-900">
          <div className="font-medium">Nothing is set up yet.</div>
          <div className="mt-1">
            Almost every school starts with <span className="font-medium">Tuition</span> (monthly),
            an <span className="font-medium">Admission Fee</span> (once, when a child joins), and an{' '}
            <span className="font-medium">Exam Fee</span>. Add those three and you can bill.
          </div>
        </div>
      )}

      <ul className="divide-y divide-slate-100 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-card">
        {heads.isLoading && <li className="px-4 py-3 text-sm text-slate-500">Loading…</li>}
        {heads.data?.map((h) => (
          <li key={h.id} className={`flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 ${h.active ? '' : 'bg-slate-50'}`}>
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-1.5">
                <span className={`font-medium ${h.active ? 'text-slate-900' : 'text-slate-500'}`}>{h.name}</span>
                <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ring-1 ${h.is_recurring ? 'bg-brand-50 text-brand-800 ring-brand-100' : 'bg-slate-100 text-slate-600 ring-slate-200'}`}>
                  {h.is_recurring ? 'every month' : 'once'}
                </span>
                {h.is_refundable && <span className="rounded-full bg-info-50 px-2 py-0.5 text-[11px] font-medium text-info-800 ring-1 ring-info-100">refundable</span>}
                {!h.active && <span className="rounded-full bg-slate-200 px-2 py-0.5 text-[11px] text-slate-600">switched off</span>}
              </div>
              <div className="text-xs text-slate-500">
                {TYPES.find((t) => t.value === h.type)?.label.split(':')[0] ?? h.type} · order {h.sort_order}
                {h.in_use ? ' · already on challans' : ''}
              </div>
            </div>
            {mayWrite && (
              <div className="flex gap-1.5">
                <Button size="sm" variant="soft" tone="brand" onClick={() => setEditing(h)}>Edit</Button>
                <Button size="sm" variant="ghost" onClick={() => toggle.mutate({ id: h.id, active: !h.active })} disabled={toggle.isPending}
                  title={h.in_use
                    ? 'This head has already been billed, so it cannot be deleted: switching it off stops it being charged and keeps past challans readable.'
                    : 'Stop charging this head'}>
                  {h.active ? 'Switch off' : 'Switch on'}
                </Button>
              </div>
            )}
          </li>
        ))}
      </ul>
      {toggle.isError && <p className="text-sm text-danger-600">{(toggle.error as Error).message}</p>}

      <div className="flex items-center justify-between">
        <label className="flex items-center gap-2 text-xs text-slate-600">
          <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
          Show ones that are switched off
        </label>
        {mayWrite && <Button onClick={() => setAdding(true)}>+ Add a fee head</Button>}
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
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 sm:items-center" role="dialog" aria-modal="true">
      <div className="w-full max-w-lg rounded-2xl bg-white p-5 shadow-pop">
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
            <p className="rounded border border-info-200 bg-info-50 px-3 py-2 text-xs text-info-900">
              A refundable head is money the school <span className="font-medium">holds</span>, not
              income. It appears as a liability on the balance sheet and can be refunded or netted
              against arrears when the child leaves. It cannot also be charged monthly.
            </p>
          )}
          {save.isError && <p className="text-sm text-danger-600">{(save.error as Error).message}</p>}
        </div>
        <div className="mt-4 flex gap-2">
          <Button className="flex-1" onClick={() => save.mutate()} disabled={save.isPending || !name.trim()}>
            {save.isPending ? 'Saving…' : 'Save'}
          </Button>
          <Button className="flex-1" variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
        </div>
      </div>
    </div>
  )
}

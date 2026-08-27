import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { getCurrentSession, getFeeStructure, listClasses, setFeeAmount } from '@/lib/db'
import { fmtDate } from '@/lib/format'

export function FeeStructure({ onSetUpHeads }: { onSetUpHeads?: () => void }) {
  const qc = useQueryClient()
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const [classId, setClassId] = useState('')
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [saved, setSaved] = useState(false)

  // Reads fn_fee_structure, which returns the amount in force TODAY plus any
  // change already scheduled. Selecting fee_structures directly returned every
  // dated row, so once a school had used the fee-increment tool this grid showed
  // an arbitrary price.
  const structure = useQuery({
    queryKey: ['feeStructure', session.data?.id, classId],
    queryFn: () => getFeeStructure(session.data!.id, classId),
    enabled: !!session.data && !!classId,
  })

  useEffect(() => {
    if (!structure.data) return
    const m: Record<string, string> = {}
    for (const r of structure.data) m[r.fee_head_id] = r.amount == null ? '' : String(r.amount)
    setAmounts(m)
  }, [structure.data])

  const save = useMutation({
    mutationFn: async () => {
      for (const r of structure.data ?? []) {
        const raw = amounts[r.fee_head_id]
        if (raw === undefined || raw === '') continue
        const val = Number(raw)
        if (!Number.isFinite(val)) continue
        // Only write what actually changed. Re-saving an unchanged row would,
        // once a scheduled rise exists, stamp a new row dated today for every
        // head on the screen.
        if (r.amount != null && Number(r.amount) === val) continue
        await setFeeAmount(session.data!.id, classId, r.fee_head_id, val)
      }
    },
    onSuccess: () => {
      setSaved(true); setTimeout(() => setSaved(false), 2500)
      qc.invalidateQueries({ queryKey: ['feeStructure'] })
    },
  })

  const rows = structure.data ?? []
  const nothingToSet = !!classId && !structure.isLoading && rows.length === 0

  return (
    <div className="max-w-2xl">
      <p className="text-sm text-slate-600">
        Set the fee amount for each fee head, per class. These feed the monthly challan run.
      </p>
      {!session.data && !session.isLoading && (
        <p className="mt-3 rounded bg-amber-50 p-3 text-sm text-amber-700">
          No current session set yet — set one under Settings → Sessions first.
        </p>
      )}

      <label className="mt-4 block max-w-xs">
        <span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)}
          className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none">
          <option value="">Select class…</option>
          {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {/* The state a brand-new school is actually in. Before there was a
          fee-heads screen this page showed an empty list and a Save button,
          which reads as "the software is broken" rather than "one step is
          missing". */}
      {nothingToSet && (
        <div className="mt-4 rounded border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900">
          <div className="font-medium">There are no fee heads yet.</div>
          <div className="mt-1">
            A fee head is a thing you charge for — Tuition, Admission Fee, Exam Fee. Create them
            first, then set an amount for each class here.
          </div>
          {onSetUpHeads && (
            <button onClick={onSetUpHeads}
              className="mt-2 font-medium text-brand-700 hover:underline">
              Set up fee heads →
            </button>
          )}
        </div>
      )}

      {classId && rows.length > 0 && (
        <form className="mt-4 space-y-2" onSubmit={(e) => { e.preventDefault(); save.mutate() }}>
          {rows.map((r) => (
            <div key={r.fee_head_id} className="flex items-center gap-3">
              <label className="flex-1 text-sm text-slate-700">
                {r.fee_head}
                {r.is_recurring && <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">monthly</span>}
                {/* A change the school has already scheduled. Showing it here is
                    what stops "why did the fee go up?" being a phone call. */}
                {r.next_from && (
                  <span className="ml-2 text-xs text-amber-700">
                    → Rs {Number(r.next_amount).toLocaleString('en-PK')} from {fmtDate(r.next_from)}
                  </span>
                )}
              </label>
              <div className="flex items-center gap-1">
                <span className="text-sm text-slate-400">Rs</span>
                <input
                  type="number" min="0" step="1"
                  value={amounts[r.fee_head_id] ?? ''}
                  onChange={(e) => setAmounts((a) => ({ ...a, [r.fee_head_id]: e.target.value }))}
                  className="w-32 rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
                />
              </div>
            </div>
          ))}
          {save.isError && <p className="text-sm text-red-600">{(save.error as Error).message}</p>}
          <div className="flex items-center gap-3 pt-2">
            <button type="submit" disabled={save.isPending}
              className="rounded bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {save.isPending ? 'Saving…' : 'Save fee structure'}
            </button>
            {saved && <span className="text-sm text-emerald-600">Saved.</span>}
          </div>
          <p className="pt-1 text-xs text-slate-500">
            Changing an amount here applies from today onwards. Challans already issued keep the
            amount they were issued at.
          </p>
        </form>
      )}
    </div>
  )
}

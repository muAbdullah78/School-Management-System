import { useEffect, useState } from 'react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { getCurrentSession, getFeeStructure, listClasses, listFeeHeads, upsertFeeStructure } from '@/lib/db'

export function FeeStructure() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const classes = useQuery({ queryKey: ['classes'], queryFn: listClasses })
  const heads = useQuery({ queryKey: ['feeHeads'], queryFn: listFeeHeads })
  const [classId, setClassId] = useState('')
  const [amounts, setAmounts] = useState<Record<string, string>>({})
  const [saved, setSaved] = useState(false)

  const structure = useQuery({
    queryKey: ['feeStructure', session.data?.id, classId],
    queryFn: () => getFeeStructure(session.data!.id, classId),
    enabled: !!session.data && !!classId,
  })

  useEffect(() => {
    if (structure.data) {
      const m: Record<string, string> = {}
      for (const [k, v] of Object.entries(structure.data)) m[k] = String(v)
      setAmounts(m)
    }
  }, [structure.data])

  const save = useMutation({
    mutationFn: async () => {
      for (const h of heads.data ?? []) {
        const raw = amounts[h.id]
        const val = Number(raw)
        if (raw !== undefined && raw !== '' && !isNaN(val)) {
          await upsertFeeStructure(session.data!.id, classId, h.id, val)
        }
      }
    },
    onSuccess: () => { setSaved(true); setTimeout(() => setSaved(false), 2500) },
  })

  return (
    <div className="max-w-xl">
      <p className="text-sm text-slate-600">Set the fee amount for each fee head, per class. These feed the monthly challan run.</p>
      {!session.data && !session.isLoading && (
        <p className="mt-3 rounded bg-amber-50 p-3 text-sm text-amber-700">No current session set yet.</p>
      )}
      <label className="mt-4 block max-w-xs">
        <span className="text-sm text-slate-600">Class</span>
        <select value={classId} onChange={(e) => setClassId(e.target.value)}
          className="mt-1 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none">
          <option value="">Select class…</option>
          {classes.data?.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
        </select>
      </label>

      {classId && (
        <form className="mt-4 space-y-2" onSubmit={(e) => { e.preventDefault(); save.mutate() }}>
          {heads.data?.map((h) => (
            <div key={h.id} className="flex items-center gap-3">
              <label className="flex-1 text-sm text-slate-700">
                {h.name}
                {h.is_recurring && <span className="ml-2 rounded bg-slate-100 px-1.5 py-0.5 text-xs text-slate-500">monthly</span>}
              </label>
              <div className="flex items-center gap-1">
                <span className="text-sm text-slate-400">Rs</span>
                <input
                  type="number" min="0" step="1"
                  value={amounts[h.id] ?? ''}
                  onChange={(e) => setAmounts((a) => ({ ...a, [h.id]: e.target.value }))}
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
        </form>
      )}
    </div>
  )
}

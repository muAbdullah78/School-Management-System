import { useQuery } from '@tanstack/react-query'
import { getCurrentSession, getDefaulters } from '@/lib/db'
import { fmtPKR } from '@/lib/format'

export function Defaulters() {
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const list = useQuery({
    queryKey: ['defaulters', session.data?.id],
    queryFn: () => getDefaulters(session.data!.id),
    enabled: !!session.data,
  })

  const total = list.data?.reduce((s, d) => s + Number(d.balance), 0) ?? 0

  return (
    <div>
      {list.isLoading && <p className="text-sm text-slate-500">Loading…</p>}
      {list.data && (
        <>
          <div className="mb-3 flex items-center gap-4 text-sm">
            <span className="rounded bg-slate-100 px-2 py-1 text-slate-700">{list.data.length} defaulters</span>
            <span className="rounded bg-red-50 px-2 py-1 font-medium text-red-700">Total outstanding: {fmtPKR(total)}</span>
          </div>
          <div className="overflow-x-auto rounded-lg bg-white shadow-sm ring-1 ring-slate-200">
            <table className="w-full text-sm">
              <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-3 py-2">GR</th><th className="px-3 py-2">Name</th>
                  <th className="px-3 py-2">Class</th><th className="px-3 py-2">Section</th>
                  <th className="px-3 py-2">Roll</th><th className="px-3 py-2 text-right">Balance</th>
                </tr>
              </thead>
              <tbody>
                {list.data.map((d) => (
                  <tr key={d.student_id} className="border-t border-slate-100">
                    <td className="px-3 py-2 text-slate-500">{d.gr_no ?? '—'}</td>
                    <td className="px-3 py-2 font-medium text-slate-800">{d.full_name}</td>
                    <td className="px-3 py-2">{d.class_name}</td>
                    <td className="px-3 py-2">{d.section_name ?? '—'}</td>
                    <td className="px-3 py-2">{d.roll_no ?? '—'}</td>
                    <td className="px-3 py-2 text-right font-semibold text-red-600">{fmtPKR(d.balance)}</td>
                  </tr>
                ))}
                {list.data.length === 0 && (
                  <tr><td colSpan={6} className="px-3 py-4 text-center text-slate-400">No defaulters — everyone is paid up.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  )
}

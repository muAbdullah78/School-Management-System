import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'
import { listAuditLog, listProfiles } from '@/lib/db'
import { ROLE_LABELS, type Role } from '@/auth/roles'
import { fmtDate } from '@/lib/format'

const ACTION_TONE: Record<string, string> = {
  INSERT: 'text-emerald-700', UPDATE: 'text-amber-700', DELETE: 'text-red-600',
}

export function AuditLog() {
  const log = useQuery({ queryKey: ['auditLog'], queryFn: () => listAuditLog(300) })
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const [entity, setEntity] = useState('')

  const nameById = useMemo(() => {
    const m = new Map<string, string>()
    for (const p of profiles.data ?? []) if (p.full_name) m.set(p.id, p.full_name)
    return m
  }, [profiles.data])

  const entities = useMemo(
    () => Array.from(new Set((log.data ?? []).map((r) => r.entity))).sort(),
    [log.data],
  )
  const rows = (log.data ?? []).filter((r) => !entity || r.entity === entity)

  return (
    <div className="max-w-4xl space-y-4">
      <div className="rounded-lg border border-slate-200 bg-white p-4">
        <div className="text-sm font-medium text-slate-800">Audit log</div>
        <p className="mt-1 text-sm text-slate-600">
          A tamper-evident trail of every change to money, marks, attendance, discounts and permissions —
          who did what, when, and (where given) why. Visible only to the owner and principal.
        </p>
        <label className="mt-3 inline-block">
          <span className="text-xs text-slate-500">Filter by area</span>
          <select value={entity} onChange={(e) => setEntity(e.target.value)}
            className="ml-2 rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
            <option value="">All</option>
            {entities.map((en) => <option key={en} value={en}>{en}</option>)}
          </select>
        </label>
      </div>

      <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">When</th><th className="px-3 py-2">Who</th><th className="px-3 py-2">Action</th><th className="px-3 py-2">Area</th><th className="px-3 py-2">Reason</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {log.isLoading && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {!log.isLoading && rows.length === 0 && <tr><td colSpan={5} className="px-3 py-3 text-slate-500">No audit entries{entity ? ' for this area' : ' yet'}.</td></tr>}
            {rows.map((r) => (
              <tr key={r.id}>
                <td className="px-3 py-2 whitespace-nowrap text-slate-500">{fmtDate(r.created_at)}</td>
                <td className="px-3 py-2 text-slate-700">
                  {r.actor ? (nameById.get(r.actor) ?? 'User') : 'System'}
                  {r.actor_role && <span className="text-slate-400"> · {ROLE_LABELS[r.actor_role as Role] ?? r.actor_role}</span>}
                </td>
                <td className={`px-3 py-2 font-medium ${ACTION_TONE[r.action] ?? 'text-slate-600'}`}>{r.action}</td>
                <td className="px-3 py-2 text-slate-600">{r.entity}</td>
                <td className="px-3 py-2 text-slate-500">{r.reason ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {log.isError && <p className="text-sm text-red-600">{(log.error as Error).message}</p>}
      <p className="text-xs text-slate-400">Showing the most recent {(log.data ?? []).length} entries.</p>
    </div>
  )
}

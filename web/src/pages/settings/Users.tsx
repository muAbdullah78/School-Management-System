import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { listProfiles, updateProfileRole, setProfileActive } from '@/lib/db'
import { ROLES, ROLE_LABELS, type Role } from '@/auth/roles'
import { useAuth } from '@/auth/AuthProvider'

export function Users() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canManage = !!profile && ['owner', 'principal'].includes(profile.role)
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })

  const role = useMutation({
    mutationFn: (v: { id: string; role: string }) => updateProfileRole(v.id, v.role),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['profiles'] }),
  })
  const active = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => setProfileActive(v.id, v.active),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['profiles'] }),
  })

  return (
    <div className="max-w-2xl space-y-3">
      {!canManage && (
        <p className="rounded bg-slate-50 p-3 text-sm text-slate-500">
          Only the owner or principal can change roles. You can view the user list.
        </p>
      )}
      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        <table className="w-full text-sm">
          <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
            <tr><th className="px-3 py-2">User</th><th className="px-3 py-2 w-56">Role</th><th className="px-3 py-2 w-28">Status</th></tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {profiles.isLoading && <tr><td colSpan={3} className="px-3 py-3 text-slate-500">Loading…</td></tr>}
            {profiles.data?.length === 0 && <tr><td colSpan={3} className="px-3 py-3 text-slate-500">No users yet.</td></tr>}
            {profiles.data?.map((p) => (
              <tr key={p.id} className={p.active ? '' : 'opacity-60'}>
                <td className="px-3 py-2 text-slate-800">{p.full_name || <span className="text-slate-400">(unnamed)</span>}{p.id === profile?.id && <span className="ml-1 text-xs text-slate-400">· you</span>}</td>
                <td className="px-3 py-2">
                  {canManage ? (
                    <select value={p.role} onChange={(e) => role.mutate({ id: p.id, role: e.target.value })}
                      className="w-full rounded border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none">
                      {ROLES.map((r) => <option key={r} value={r}>{ROLE_LABELS[r as Role]}</option>)}
                    </select>
                  ) : (
                    <span className="text-slate-600">{ROLE_LABELS[p.role as Role] ?? p.role}</span>
                  )}
                </td>
                <td className="px-3 py-2">
                  {canManage && p.id !== profile?.id ? (
                    <button onClick={() => active.mutate({ id: p.id, active: !p.active })} disabled={active.isPending}
                      className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                      {p.active ? 'Deactivate' : 'Activate'}
                    </button>
                  ) : (
                    <span className="text-xs text-slate-500">{p.active ? 'Active' : 'Inactive'}</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {(role.isError || active.isError) && (
        <p className="text-sm text-red-600">{((role.error ?? active.error) as Error)?.message}</p>
      )}
      <p className="text-xs text-slate-500">
        New logins are created in Supabase Auth (email + password); each person gets a profile row here on first sign-in,
        which you then assign a role. Deactivating blocks a user without deleting their history.
      </p>
    </div>
  )
}

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listProfiles, updateProfileRole, setProfileActive,
  inviteUser, listPendingInvites, revokeInvite,
} from '@/lib/db'
import { ROLES, ROLE_LABELS, type Role } from '@/auth/roles'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDate } from '@/lib/format'

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none'

// An owner is never invited. The first account of a school becomes owner at
// signup, and later owners are promoted on this screen by an existing owner —
// so the school's top privilege never sits behind an email address.
const INVITABLE = ROLES.filter((r) => r !== 'owner')

export function Users() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const canManage = !!profile && ['owner', 'principal'].includes(profile.role)
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const invites = useQuery({
    queryKey: ['pendingInvites'], queryFn: listPendingInvites, enabled: canManage,
  })

  const [email, setEmail] = useState('')
  const [name, setName] = useState('')
  const [inviteRole, setInviteRole] = useState<string>('class_teacher')
  const [sent, setSent] = useState<string | null>(null)

  const role = useMutation({
    mutationFn: (v: { id: string; role: string }) => updateProfileRole(v.id, v.role),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['profiles'] }),
  })
  const active = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => setProfileActive(v.id, v.active),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['profiles'] }),
  })
  const invite = useMutation({
    mutationFn: () => inviteUser(email, inviteRole, name),
    onSuccess: (r) => {
      setSent(r.email); setEmail(''); setName('')
      qc.invalidateQueries({ queryKey: ['pendingInvites'] })
    },
  })
  const revoke = useMutation({
    mutationFn: (id: string) => revokeInvite(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pendingInvites'] }),
  })

  return (
    <div className="max-w-3xl space-y-4">
      {!canManage && (
        <p className="rounded bg-slate-50 p-3 text-sm text-slate-500">
          Only the owner or principal can invite people or change roles. You can view the user list.
        </p>
      )}

      {/* Invite */}
      {canManage && (
        <div className="rounded-lg border border-slate-200 bg-white p-4">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Invite someone to this school
          </div>
          <p className="mt-1 text-xs text-slate-500">
            They sign up with this email address and choose their own password. The role you pick
            here is what they get — nothing they type at signup can change it.
          </p>
          <div className="mt-3 flex flex-wrap items-end gap-2">
            <label className="block">
              <span className="text-xs text-slate-600">Email address</span>
              <input value={email} onChange={(e) => { setEmail(e.target.value); setSent(null) }}
                type="email" placeholder="teacher@school.pk" className={`${FIELD} mt-1 w-56`} />
            </label>
            <label className="block">
              <span className="text-xs text-slate-600">Name (optional)</span>
              <input value={name} onChange={(e) => setName(e.target.value)}
                placeholder="Miss Ayesha" className={`${FIELD} mt-1 w-44`} />
            </label>
            <label className="block">
              <span className="text-xs text-slate-600">Role</span>
              <select value={inviteRole} onChange={(e) => setInviteRole(e.target.value)}
                className={`${FIELD} mt-1`}>
                {INVITABLE.map((r) => <option key={r} value={r}>{ROLE_LABELS[r as Role]}</option>)}
              </select>
            </label>
            <button onClick={() => invite.mutate()}
              disabled={invite.isPending || !email.trim()}
              className="rounded bg-brand-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
              {invite.isPending ? 'Inviting…' : 'Send invitation'}
            </button>
          </div>
          {invite.isError && <p className="mt-2 text-sm text-red-600">{(invite.error as Error).message}</p>}
          {sent && (
            <p className="mt-2 rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800">
              Invitation ready for <span className="font-medium">{sent}</span>. Tell them to open the
              app, choose <span className="font-medium">Create an account</span>, and sign up with
              exactly that address. It is valid for 7 days.
            </p>
          )}
        </div>
      )}

      {/* Pending invitations */}
      {canManage && (invites.data?.length ?? 0) > 0 && (
        <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
          <div className="border-b border-slate-100 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
            Waiting to sign up
          </div>
          <table className="w-full text-sm">
            <tbody className="divide-y divide-slate-100">
              {invites.data?.map((i) => (
                <tr key={i.id} className={i.expired ? 'opacity-60' : ''}>
                  <td className="px-3 py-2 text-slate-800">
                    {i.email}
                    {i.full_name && <span className="text-slate-500"> · {i.full_name}</span>}
                  </td>
                  <td className="px-3 py-2 text-slate-600">{ROLE_LABELS[i.role as Role] ?? i.role}</td>
                  <td className="px-3 py-2 text-xs text-slate-500">
                    {i.expired
                      ? <span className="text-amber-700">Expired {fmtDate(i.expires_at)} — invite again</span>
                      : <>Expires {fmtDate(i.expires_at)}</>}
                    {i.invited_by && <span className="text-slate-400"> · by {i.invited_by}</span>}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <button onClick={() => revoke.mutate(i.id)} disabled={revoke.isPending}
                      className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                      Withdraw
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {revoke.isError && <p className="px-3 py-2 text-sm text-red-600">{(revoke.error as Error).message}</p>}
        </div>
      )}

      {/* Existing users */}
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
        Invite people rather than creating logins for them: the role travels with the invitation,
        so nothing a person types while signing up can give them a role you did not choose.
        Deactivating blocks someone without deleting their history.
      </p>
    </div>
  )
}

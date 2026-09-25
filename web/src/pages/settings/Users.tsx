import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listProfiles, updateProfileRole, setProfileActive, listSchoolLogins,
  inviteUser, listPendingInvites, revokeInvite, assignableRoles, type ProfileRow,
} from '@/lib/db'
import { ASSIGNABLE_ROLES, ROLE_LABELS, isRetired, type LiveRole, type Role } from '@/auth/roles'
import { useAuth } from '@/auth/AuthProvider'
import { fmtDate } from '@/lib/format'
import { LoadError, Button, inputClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { KeyRing } from './KeyRing'
import { useEmailCheck, EmailVerdictLine } from '@/components/EmailAvailability'

/**
 * ASSIGNABLE_ROLES already excludes the owner and, since 0133, the two
 * withdrawn office roles. Parent is taken out as well here: a parent login is
 * made from the child's profile, where it is joined to the family, and one
 * invited from here belonged to nobody's children.
 *
 * The screen also asks the database (fn_assignable_roles) and prefers that
 * answer; the local list is the fallback for a school without bundle 38.
 */
const STAFF_ROLES: LiveRole[] = ASSIGNABLE_ROLES.filter((r) => r !== 'parent')

/** What each role can do, in the words a head teacher would use. */
const CAN: Record<string, string> = {
  owner: 'Everything, including access for everybody else and the account with us.',
  principal: 'Runs the school day to day: admissions, fees, staff, reports and settings. Does not mark the register.',
  class_teacher: 'Marks the register of their own class, enters marks for every subject in it, and writes the report-card remark.',
  subject_teacher: 'Enters marks only for the subjects listed against them under Staff, Subject teachers.',
  readonly: 'Sees everything and can change nothing. For a trustee, an inspector or an auditor.',
}

function useAssignableRoles(): LiveRole[] {
  const q = useQuery({ queryKey: ['assignableRoles'], queryFn: assignableRoles, staleTime: Infinity })
  const fromDb = q.data
  if (!fromDb || fromDb.length === 0) return STAFF_ROLES
  // Only values this build knows how to label.
  return STAFF_ROLES.filter((r) => fromDb.includes(r))
}

/**
 * Who can sign in, and as what.
 *
 * WHAT WAS WRONG, AND IT WAS DANGEROUS.
 *
 *   * Every PARENT login was a row here, each with a role dropdown, so a school
 *     with 200 families scrolled past 200 parents to find a teacher, and one
 *     slip turned a parent into a Principal with the run of the school.
 *   * The dropdown changed the role THE MOMENT it was touched. No question, no
 *     undo, no message.
 *   * The owner's row showed a dropdown that did not contain "Owner", and a
 *     select whose value is not among its options shows the first one, so the
 *     owner read as "Principal / Headmaster" on their own screen.
 *   * A principal could change their own role, and the database let a
 *     principal make themselves, or anybody, an owner (0148 closes that).
 *   * It showed no email address and no last sign-in, which are the two facts
 *     that tell you whether a login is still in use.
 *
 * Now staff logins are listed with both, parents are counted and pointed at
 * the child's profile, and every change asks first and says what it gives.
 */
export function Users() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const assignable = useAssignableRoles()
  const canManage = !!profile && ['owner', 'principal'].includes(profile.role)
  const iAmOwner = profile?.role === 'owner'
  const profiles = useQuery({ queryKey: ['profiles'], queryFn: listProfiles })
  const logins = useQuery({ queryKey: ['schoolLogins'], queryFn: listSchoolLogins, enabled: canManage, retry: false })
  const invites = useQuery({ queryKey: ['pendingInvites'], queryFn: listPendingInvites, enabled: canManage })

  const [email, setEmail] = useState('')
  const [name, setName] = useState('')
  const emailCheck = useEmailCheck()
  const [inviteRole, setInviteRole] = useState<string>('class_teacher')
  const [sent, setSent] = useState<string | null>(null)
  const [changing, setChanging] = useState<ProfileRow | null>(null)
  const [closing, setClosing] = useState<ProfileRow | null>(null)
  const [showClosed, setShowClosed] = useState(false)
  const [flash, setFlash] = useState<string | null>(null)

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
  const active = useMutation({
    mutationFn: (v: { id: string; active: boolean }) => setProfileActive(v.id, v.active),
    onSuccess: (_d, v) => {
      const who = (profiles.data ?? []).find((p) => p.id === v.id)?.full_name || 'That login'
      setFlash(v.active ? `${who} can sign in again.` : `${who} can no longer sign in. Nothing they did is removed.`)
      setClosing(null)
      qc.invalidateQueries({ queryKey: ['profiles'] }); qc.invalidateQueries({ queryKey: ['schoolLogins'] }); qc.invalidateQueries({ queryKey: ['staff'] })
    },
  })

  const all = profiles.data ?? []
  const staffLogins = all.filter((p) => p.role !== 'parent')
  const parents = all.filter((p) => p.role === 'parent')
  const openStaff = staffLogins.filter((p) => p.active)
  const closedStaff = staffLogins.filter((p) => !p.active)
  const info = (id: string) => (logins.data ?? []).find((l) => l.profile_id === id)
  const waiting = (invites.data ?? []).filter((i) => !i.expired)
  const byRole = STAFF_ROLES.concat(['owner'] as LiveRole[]).map((r) => ({ r, n: openStaff.filter((p) => p.role === r).length }))

  // Who may touch which row. The database enforces the same (0148).
  const mayChange = (p: ProfileRow) => canManage && p.id !== profile?.id && (p.role !== 'owner' || iAmOwner)

  return (
    <div className="max-w-4xl space-y-4">
      <LoadError of={[profiles, invites]} what="The list of logins" />
      {!canManage && (
        <p className="rounded-xl bg-slate-50 p-3 text-sm text-slate-600">
          Only the owner or principal can invite people or change what they can do. You can see the list.
        </p>
      )}

      <div className="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <Stat n={openStaff.length} label="staff can sign in" tone="brand" />
        <Stat n={waiting.length} label={waiting.length === 1 ? 'invitation waiting' : 'invitations waiting'} tone={waiting.length ? 'due' : 'plain'} />
        <Stat n={closedStaff.length} label="closed" />
        <Stat n={parents.length} label="parent logins" />
      </div>
      {openStaff.length > 0 && (
        <p className="text-xs text-slate-500">
          {byRole.filter((x) => x.n).map((x) => `${x.n} ${ROLE_LABELS[x.r]}${x.n === 1 ? '' : 's'}`).join(' · ')}
        </p>
      )}

      {flash && (
        <div className="flex items-start justify-between gap-3 rounded-xl border border-brand-200 bg-brand-50 px-4 py-3 text-sm text-brand-800">
          <span>{flash}</span>
          <button onClick={() => setFlash(null)} className="shrink-0 text-brand-700 hover:underline">Dismiss</button>
        </div>
      )}

      {/* ----------------------------------------------------- invite -- */}
      {canManage && (
        <section className="rounded-2xl border border-slate-200 bg-white p-4 shadow-card sm:p-5">
          <h3 className="text-sm font-semibold text-slate-900">Invite someone to the staff</h3>
          <p className="mt-0.5 text-xs text-slate-500">
            They sign up with this address and choose their own password. The role you pick here is what they
            get: nothing they type at signup can change it. To give a teacher a login straight away instead, use
            Give a login on their row under Staff.
          </p>
          <div className="mt-3 grid gap-3 sm:grid-cols-3">
            <label className="block">
              <span className="mb-1 block text-xs font-medium text-slate-600">Email address</span>
              <input value={email} type="email" inputMode="email" placeholder="teacher@school.pk" className={inputClass}
                onChange={(e) => { setEmail(e.target.value); setSent(null); emailCheck.clear() }}
                onBlur={() => void emailCheck.check(email)} />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-medium text-slate-600">Name (optional)</span>
              <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Miss Ayesha" className={inputClass} />
            </label>
            <label className="block">
              <span className="mb-1 block text-xs font-medium text-slate-600">They will be</span>
              <select value={inviteRole} onChange={(e) => setInviteRole(e.target.value)} className={inputClass}>
                {assignable.map((r) => <option key={r} value={r}>{ROLE_LABELS[r]}</option>)}
              </select>
            </label>
          </div>
          <p className="mt-2 text-xs text-slate-500">{CAN[inviteRole]}</p>
          <EmailVerdictLine verdict={emailCheck.verdict} checking={emailCheck.checking} />
          {/* BLOCKED ONLY ON A KNOWN NO: the database enforces uniqueness
              whatever this screen believes. */}
          <div className="mt-3">
            <Button onClick={() => invite.mutate()}
              disabled={invite.isPending || !/^\S+@\S+\.\S+$/.test(email.trim()) || emailCheck.checking || emailCheck.verdict?.available === false}>
              {invite.isPending ? 'Inviting…' : 'Send the invitation'}
            </Button>
          </div>
          {invite.isError && <p className="mt-2 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(invite.error as Error).message}</p>}
          {sent && (
            <p className="mt-2 rounded-xl border border-brand-200 bg-brand-50 px-3 py-2 text-sm text-brand-800">
              Invitation ready for <b>{sent}</b>. Tell them to open the app, choose <b>Create an account</b>,
              and sign up with exactly that address. It lasts 7 days.
            </p>
          )}
        </section>
      )}

      {/* --------------------------------------------------- waiting -- */}
      {canManage && (invites.data?.length ?? 0) > 0 && (
        <section className="rounded-2xl border border-slate-200 bg-white shadow-card">
          <h3 className="border-b border-slate-100 px-4 py-2.5 text-sm font-semibold text-slate-900">Invited, not signed up yet</h3>
          <ul className="divide-y divide-slate-100">
            {invites.data!.map((i) => (
              <li key={i.id} className={`flex flex-wrap items-center justify-between gap-2 px-4 py-2.5 ${i.expired ? 'opacity-70' : ''}`}>
                <div className="min-w-0">
                  <div className="truncate text-sm text-slate-900">{i.email}{i.full_name && <span className="text-slate-500"> · {i.full_name}</span>}</div>
                  <div className="text-xs text-slate-500">
                    {ROLE_LABELS[i.role as Role] ?? i.role} ·{' '}
                    {i.expired ? <span className="font-medium text-due-800">ran out {fmtDate(i.expires_at)}: invite again</span> : <>lasts until {fmtDate(i.expires_at)}</>}
                    {i.invited_by && <> · by {i.invited_by}</>}
                  </div>
                </div>
                <Button size="sm" variant="ghost" onClick={() => revoke.mutate(i.id)} disabled={revoke.isPending}>Withdraw</Button>
              </li>
            ))}
          </ul>
          {revoke.isError && <p className="px-4 py-2 text-sm text-danger-700">{(revoke.error as Error).message}</p>}
        </section>
      )}

      {/* ------------------------------------------------ staff logins -- */}
      <section className="rounded-2xl border border-slate-200 bg-white shadow-card">
        <h3 className="border-b border-slate-100 px-4 py-2.5 text-sm font-semibold text-slate-900">Staff who can sign in</h3>
        {profiles.isLoading && <p className="px-4 py-3 text-sm text-slate-500">Loading…</p>}
        <ul className="divide-y divide-slate-100">
          {(showClosed ? staffLogins : openStaff).map((p) => {
            const l = info(p.id)
            const me = p.id === profile?.id
            return (
              <li key={p.id} className={`flex flex-wrap items-center gap-x-4 gap-y-2 px-4 py-3 ${p.active ? '' : 'bg-slate-50'}`}>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-1.5">
                    <span className={`font-medium ${p.active ? 'text-slate-900' : 'text-slate-500'}`}>{p.full_name || '(no name)'}</span>
                    {me && <span className="text-xs text-slate-400">you</span>}
                    <span className={`rounded-full px-2 py-0.5 text-[11px] font-medium ring-1 ${
                      p.role === 'owner' ? 'bg-brand-600 text-white ring-brand-600'
                        : isRetired(p.role as Role) ? 'bg-due-50 text-due-800 ring-due-200'
                        : 'bg-brand-50 text-brand-800 ring-brand-100'}`}>
                      {ROLE_LABELS[p.role as Role] ?? p.role}
                    </span>
                    {!p.active && <span className="rounded-full bg-slate-200 px-2 py-0.5 text-[11px] text-slate-600">closed</span>}
                  </div>
                  <div className="truncate text-xs text-slate-500">
                    {l?.email ?? ''}
                    {l ? (l.last_sign_in_at ? ` · last signed in ${fmtDate(l.last_sign_in_at)}` : ' · has never signed in') : ''}
                    {l ? (l.staff_name ? ` · ${l.staff_name} on the staff list` : ' · not on the staff list') : ''}
                  </div>
                  {isRetired(p.role as Role) && (
                    <div className="text-xs font-medium text-due-800">This role has been withdrawn. Give them Principal or Read only.</div>
                  )}
                </div>
                {mayChange(p) && (
                  <div className="flex gap-1.5">
                    {p.active && <Button size="sm" variant="soft" tone="brand" onClick={() => setChanging(p)}>Change role</Button>}
                    <Button size="sm" variant="ghost" onClick={() => { active.reset(); if (p.active) setClosing(p); else active.mutate({ id: p.id, active: true }) }}>
                      {p.active ? 'Close login' : 'Reopen'}
                    </Button>
                  </div>
                )}
                {canManage && !mayChange(p) && !me && p.role === 'owner' && <span className="text-xs text-slate-400">Only an owner can change an owner</span>}
              </li>
            )
          })}
        </ul>
        {closedStaff.length > 0 && (
          <button type="button" onClick={() => setShowClosed(!showClosed)} className="w-full border-t border-slate-100 px-4 py-2 text-left text-sm font-medium text-brand-700 hover:bg-slate-50">
            {showClosed ? 'Hide the closed logins' : `Show the ${closedStaff.length} closed login${closedStaff.length === 1 ? '' : 's'}`}
          </button>
        )}
        {active.isError && !closing && <p className="px-4 py-2 text-sm text-danger-700">{(active.error as Error).message}</p>}
      </section>

      {parents.length > 0 && (
        <p className="rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm text-slate-600">
          <b className="text-slate-900">{parents.length} parent login{parents.length === 1 ? '' : 's'}</b> {parents.length === 1 ? 'is' : 'are'} not
          listed here. A parent&rsquo;s login is made, reset and removed from their child&rsquo;s profile, in the Parent portal
          box, where it is joined to the right family.
        </p>
      )}

      {/* THE ONE HOME FOR SAVED PASSWORDS. */}
      {canManage && <KeyRing />}

      {changing && (
        <RoleDialog p={changing} choices={iAmOwner ? [...assignable, 'owner'] : assignable}
          onClose={() => setChanging(null)}
          onDone={(role) => {
            setChanging(null)
            setFlash(`${changing.full_name || 'That login'} is now ${ROLE_LABELS[role as Role] ?? role}.`)
            qc.invalidateQueries({ queryKey: ['profiles'] }); qc.invalidateQueries({ queryKey: ['schoolLogins'] })
          }} />
      )}
      {closing && (
        <AskDialog
          title={`Close ${closing.full_name || 'this'} login?`}
          intro={<>They will not be able to sign in from any phone or computer, from now. Everything they did stays exactly as it is,
            and the login can be reopened later. If they have left the school, record that on the Staff screen instead: it also
            frees any class they ran.</>}
          confirmLabel="Close the login"
          tone="danger"
          busy={active.isPending}
          error={active.error ? (active.error as Error).message : null}
          onCancel={() => setClosing(null)}
          onSubmit={() => active.mutate({ id: closing.id, active: false })}
        />
      )}
    </div>
  )
}

function Stat({ n, label, tone = 'plain' }: { n: number; label: string; tone?: 'brand' | 'due' | 'plain' }) {
  const skin = tone === 'brand' ? 'border-brand-100 bg-brand-50 text-brand-900' : tone === 'due' ? 'border-due-200 bg-due-50 text-due-900' : 'border-slate-200 bg-white text-slate-900'
  return (
    <div className={`rounded-2xl border px-4 py-3 ${skin}`}>
      <div className="text-2xl font-semibold tabular-nums">{n}</div>
      <div className="text-xs opacity-80">{label}</div>
    </div>
  )
}

function RoleDialog({ p, choices, onClose, onDone }: {
  p: ProfileRow; choices: string[]; onClose: () => void; onDone: (role: string) => void
}) {
  const [role, setRole] = useState(choices.includes(p.role) ? p.role : choices[0])
  const save = useMutation({ mutationFn: () => updateProfileRole(p.id, role), onSuccess: () => onDone(role) })
  return (
    <div className="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/40 p-4 sm:items-center" role="dialog" aria-modal="true" aria-label={`Change what ${p.full_name} can do`}>
      <div className="w-full max-w-lg rounded-2xl bg-white p-5 shadow-pop">
        <h2 className="text-base font-semibold text-slate-900">What should {p.full_name || 'this login'} be able to do?</h2>
        <p className="mt-0.5 text-sm text-slate-500">Now: {ROLE_LABELS[p.role as Role] ?? p.role}. It changes the next time they open a screen.</p>
        <fieldset className="mt-4 space-y-2">
          <legend className="sr-only">Role</legend>
          {choices.map((r) => (
            <label key={r} className={`flex cursor-pointer items-start gap-3 rounded-xl border p-3 ${role === r ? 'border-brand-400 bg-brand-50 ring-1 ring-brand-200' : 'border-slate-200 hover:bg-slate-50'}`}>
              <input type="radio" name="role" value={r} checked={role === r} onChange={() => setRole(r)} className="mt-1 accent-brand-600" />
              <span>
                <span className="block text-sm font-semibold text-slate-900">{ROLE_LABELS[r as Role] ?? r}{r === p.role ? ' (now)' : ''}</span>
                <span className="block text-xs text-slate-600">{CAN[r]}</span>
              </span>
            </label>
          ))}
        </fieldset>
        {role === 'owner' && p.role !== 'owner' && (
          <p className="mt-3 rounded-xl border border-danger-200 bg-danger-50 px-3 py-2 text-xs text-danger-800">
            An owner can do everything you can, including removing you. Make someone an owner only if they own the school.
          </p>
        )}
        {save.isError && <p className="mt-3 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(save.error as Error).message}</p>}
        <div className="mt-4 flex gap-2">
          <Button className="flex-1" onClick={() => save.mutate()} disabled={save.isPending || role === p.role}>
            {save.isPending ? 'Saving…' : role === p.role ? 'No change' : `Make them ${ROLE_LABELS[role as Role] ?? role}`}
          </Button>
          <Button className="flex-1" variant="soft" tone="neutral" onClick={onClose}>Cancel</Button>
        </div>
      </div>
    </div>
  )
}

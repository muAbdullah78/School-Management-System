import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  schoolKeyRing, revealLoginPassword, setLoginPassword, forgetLoginPassword,
  type KeyRingRow,
} from '@/lib/db'
import { ROLE_LABELS, type Role } from '@/auth/roles'
import { fmtDate } from '@/lib/format'

const FIELD = 'rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none'

/**
 * The passwords this school gave out.
 *
 * WHY IT EXISTS, WHICH IS NOT THE USUAL REASON
 *
 * A Pakistani private school does not collect working email addresses from
 * parents. It invents them, or reuses one it has. So "Forgot password" posts a
 * reset link into a mailbox nobody owns, and a parent who forgets their
 * password is locked out permanently: the office cannot reset it, and cannot
 * make a replacement login either, because the address is taken by the login
 * they are trying to replace. Until this screen the app said so in as many
 * words, on the student profile: "The password is not saved anywhere you can
 * read it back."
 *
 * WHY STORING A PASSWORD IS DEFENSIBLE HERE AND ALMOST NOWHERE ELSE
 *
 * An owner or principal can already set any password in their school to
 * whatever they like, so they already hold access to every parent and teacher
 * account in the building. Remembering the one they chose grants them nothing;
 * it saves them from overwriting somebody's working password in order to help
 * them. The owner's OWN password is never here, because one leaked owner
 * credential is the whole school rather than one family, and an owner has a
 * real address with working recovery.
 *
 * WHAT THE SCREEN OWES THE READER
 *
 * The plain truth about what it is, before they read anything off it. Anybody
 * looking at this page can sign in as any of these people, every reveal is
 * counted with their name against it, and the count is on the same page so an
 * owner can see what their principal has been reading. A page that quietly
 * hands out credentials without saying that is worse than no page.
 */
export function KeyRing() {
  const qc = useQueryClient()
  const ring = useQuery({ queryKey: ['keyRing'], queryFn: schoolKeyRing, retry: false })
  const [shown, setShown] = useState<Record<string, string>>({})
  const [changing, setChanging] = useState<KeyRingRow | null>(null)

  const reveal = useMutation({
    mutationFn: (id: string) => revealLoginPassword(id),
    onSuccess: (r, id) => {
      setShown((s) => ({ ...s, [id]: r.password }))
      // Refetched so the reveal count on the row goes up in front of the person
      // who caused it. A counter nobody sees increment is a counter nobody
      // believes is being kept.
      void qc.invalidateQueries({ queryKey: ['keyRing'] })
    },
  })
  const forget = useMutation({
    mutationFn: (id: string) => forgetLoginPassword(id),
    onSuccess: (_r, id) => {
      setShown((s) => { const n = { ...s }; delete n[id]; return n })
      void qc.invalidateQueries({ queryKey: ['keyRing'] })
    },
  })

  const rows = ring.data ?? []
  const saved = rows.filter((r) => r.has_password)
  const stale = saved.filter((r) => r.changed_since)

  if (ring.isError) {
    const msg = (ring.error as Error).message
    // A school that has not applied bundle 22 gets "function does not exist",
    // which reads as a broken screen. It is a missing migration, and the
    // difference is the whole of what to do about it.
    const behind = /does not exist|schema cache/i.test(msg)
    return (
      <div className="rounded-lg border border-due-200 bg-due-50 p-3 text-sm text-due-800">
        {behind
          ? 'This school’s database does not have the key ring yet. Apply '
            + 'bundle 22 and this screen will fill itself in.'
          : `The key ring could not be loaded: ${msg}`}
      </div>
    )
  }

  return (
    <div className="rounded-lg border border-slate-200 bg-white">
      <div className="border-b border-slate-100 p-4">
        <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
          Passwords you gave out
        </div>
        <p className="mt-1 text-sm text-slate-600">
          The addresses you give parents and staff do not have to be real, and
          most of them are not, so <b>Forgot password</b> cannot help them. This
          is where the password you chose is kept, so you can tell them again.
        </p>
        {/* SAID BEFORE ANYTHING IS READ OFF THE PAGE, not in a footnote. */}
        <p className="mt-2 rounded border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-800">
          Anyone who can open this page can sign in as any of these people. Every
          time a password is shown it is recorded with the name of whoever showed
          it, and you can see that on the row. Your own owner password is never
          kept here.
        </p>
        {stale.length > 0 && (
          <p className="mt-2 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
            {stale.length === 1
              ? 'One of these people has changed their own password since, so what is saved for them will not work.'
              : `${stale.length} of these people have changed their own passwords since, so what is saved for them will not work.`}
            {' '}Use <b>Change password</b> on their row.
          </p>
        )}
      </div>

      {ring.isLoading && <p className="p-4 text-sm text-slate-500">Loading…</p>}
      {!ring.isLoading && rows.length === 0 && (
        <p className="p-4 text-sm text-slate-500">
          Nobody but you has a login yet. Add staff on the Staff screen, and
          parents from a child&rsquo;s profile.
        </p>
      )}

      {rows.length > 0 && (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="bg-slate-50 text-left text-xs uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-3 py-2 font-medium">Who</th>
                <th className="px-3 py-2 font-medium">Signs in as</th>
                <th className="px-3 py-2 font-medium">Password</th>
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.profile_id} className={r.active ? '' : 'opacity-60'}>
                  <td className="px-3 py-2 align-top">
                    <div className="text-slate-800">
                      {r.full_name || <span className="text-slate-400">(unnamed)</span>}
                    </div>
                    <div className="text-xs text-slate-500">
                      {ROLE_LABELS[r.role as Role] ?? r.role.replace(/_/g, ' ')}
                      {!r.active && ' · closed'}
                    </div>
                  </td>
                  <td className="px-3 py-2 align-top">
                    <span className="break-all font-mono text-xs text-slate-700">
                      {r.email ?? 'no address'}
                    </span>
                  </td>
                  <td className="px-3 py-2 align-top">
                    {!r.has_password ? (
                      <span className="text-xs text-slate-500">
                        Not saved. Set one to be able to tell them again.
                      </span>
                    ) : shown[r.profile_id] ? (
                      <>
                        <span className="break-all rounded bg-slate-100 px-1.5 py-0.5 font-mono text-sm text-slate-900">
                          {shown[r.profile_id]}
                        </span>
                        {r.changed_since && (
                          <span className="mt-1 block text-xs text-due-800">
                            They have changed it themselves since, so this will
                            not work.
                          </span>
                        )}
                      </>
                    ) : (
                      <div className="text-xs text-slate-500">
                        {r.changed_since ? (
                          <span className="text-due-800">
                            Changed by them since, so what is saved will not work
                          </span>
                        ) : (
                          <>Saved{r.set_at ? ` ${fmtDate(r.set_at)}` : ''}
                          {r.set_by_name ? ` by ${r.set_by_name}` : ''}</>
                        )}
                        {r.reads > 0 && (
                          <span className="mt-0.5 block text-slate-400">
                            Shown {r.reads} {r.reads === 1 ? 'time' : 'times'}
                            {r.read_by_name ? `, last by ${r.read_by_name}` : ''}
                            {r.read_at ? ` on ${fmtDate(r.read_at)}` : ''}
                          </span>
                        )}
                      </div>
                    )}
                  </td>
                  <td className="px-3 py-2 text-right align-top">
                    <div className="inline-flex flex-wrap justify-end gap-1.5">
                      {r.has_password && !shown[r.profile_id] && (
                        <button
                          onClick={() => reveal.mutate(r.profile_id)}
                          disabled={reveal.isPending}
                          className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
                        >
                          Show
                        </button>
                      )}
                      {shown[r.profile_id] && (
                        <button
                          onClick={() => setShown((s) => {
                            const n = { ...s }; delete n[r.profile_id]; return n
                          })}
                          className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          Hide
                        </button>
                      )}
                      <button
                        onClick={() => setChanging(r)}
                        className="rounded border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                      >
                        {r.has_password ? 'Change password' : 'Set a password'}
                      </button>
                      {r.has_password && (
                        <button
                          onClick={() => forget.mutate(r.profile_id)}
                          disabled={forget.isPending}
                          className="rounded px-2.5 py-1 text-xs text-slate-500 hover:bg-slate-100 disabled:opacity-60"
                        >
                          Forget
                        </button>
                      )}
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {(reveal.isError || forget.isError) && (
        <p className="border-t border-slate-100 px-3 py-2 text-sm text-danger-700">
          {((reveal.error ?? forget.error) as Error).message}
        </p>
      )}

      {changing && (
        <ChangePassword
          row={changing}
          onClose={() => setChanging(null)}
          onDone={() => {
            setChanging(null)
            void qc.invalidateQueries({ queryKey: ['keyRing'] })
          }}
        />
      )}
    </div>
  )
}

/**
 * Setting somebody a new password.
 *
 * TYPED, NOT GENERATED. A generated password is stronger and is the wrong
 * answer here: this one gets read out over a telephone to a parent who will type
 * it on a phone keyboard, and "Xk9#mQ2!" read aloud in Urdu over a bad line is
 * how a family ends up locked out twice. The office picks something they can
 * say.
 *
 * IT IS NOT HIDDEN EITHER. A masked field would be protecting the password from
 * the one person who is about to be shown it anyway, on the row above, by
 * design, and masking invites a typo nobody can see in the one field where a
 * typo means a lockout.
 */
function ChangePassword({ row, onClose, onDone }: {
  row: KeyRingRow
  onClose: () => void
  onDone: () => void
}) {
  const [password, setPassword] = useState('')
  const save = useMutation({
    mutationFn: () => setLoginPassword(row.profile_id, password),
    onSuccess: onDone,
  })
  const valid = password.trim().length >= 6

  return (
    <div className="border-t border-slate-100 bg-slate-50 p-4">
      <div className="text-sm font-medium text-slate-800">
        New password for {row.full_name || row.email}
      </div>
      <p className="mt-1 text-xs text-slate-500">
        They can sign in with it straight away, and it is saved here so you can
        tell them again. Something they can type on a phone: six characters or
        more.
      </p>
      <form
        className="mt-2 flex flex-wrap items-center gap-2"
        onSubmit={(e) => { e.preventDefault(); if (valid) save.mutate() }}
      >
        <input
          value={password} onChange={(e) => setPassword(e.target.value)}
          autoFocus type="text" placeholder="new password"
          className={`${FIELD} w-56 font-mono`}
        />
        <button
          type="submit" disabled={!valid || save.isPending}
          className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
        >
          {save.isPending ? 'Saving…' : 'Set it'}
        </button>
        <button
          type="button" onClick={onClose}
          className="rounded border border-slate-300 px-3 py-1.5 text-sm text-slate-600 hover:bg-white"
        >
          Cancel
        </button>
      </form>
      {save.isError && (
        <p className="mt-2 text-sm text-danger-700">{(save.error as Error).message}</p>
      )}
    </div>
  )
}

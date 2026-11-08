// Offline work: what this device holds for the signed-in login, what needs a
// decision, and what the server said about what it has already taken.
import { useState } from 'react'
import { useOffline } from '@/offline/OfflineProvider'
import { ago } from '@/offline/OfflineStatus'
import { receiptsLeft } from '@/offline/receipts'
import { refusalFor } from '@/offline/engine'
import type { DoneItem, OutboxItem } from '@/offline/store'
import { AskDialog } from '@/components/AskDialog'
import { fmtDateTime } from '@/lib/format'

/** What a person can do about a refused entry. */
function actionsFor(item: OutboxItem): { resend?: string; patch?: Record<string, unknown>; hint?: string } {
  switch (item.code) {
    case 'possible_duplicate':
      return { resend: 'Admit anyway', patch: { allow_duplicate: true },
        hint: 'Check the child already on the roll first. Admit anyway only if they are a different child.' }
    case 'duplicate':
      return { hint: 'The school already has this, so nothing is missing. It can be discarded.' }
    case 'too_old':
      return { hint: 'If this was sent before, the school may already have it. Check before entering it again on a connected device, then discard this.' }
    case 'bad_date':
    case 'clock_ahead':
      return { hint: 'Check the date and time on this device. Sending it again would be refused the same way, so enter it again with the right date if it is still needed, then discard this.' }
    case 'outside_lease':
    case 'device_revoked':
    case 'login_off':
    case 'dependency_discarded':
      return { hint: 'Sending it again would be refused the same way. Enter it again on a connected device if it is still needed, then discard this.' }
    case 'not_on_sheet':
      return { hint: 'Nobody in this entry is on the register or sheet any more (left, moved, or no longer yours to mark). The school has it on record. Discard this once you have checked.' }
    case 'held':
      return {}
    default:
      return { resend: 'Send again', hint: 'Send it again once the problem is fixed, for example after the office corrects the record.' }
  }
}

const REGISTERS_AND_MARKS = new Set(['attendance.day', 'attendance.subject', 'marks.exam', 'marks.test'])

/** The notice worth reading about something the server has taken. */
export function noticeFor(d: DoneItem): string | null {
  const r = d.result ?? {}
  const parts: string[] = []
  if (d.flags.includes('receipt_renumbered')) {
    const printed = r.printed_receipt_no
    const kept = r.receipt_no ?? r.admission_receipt_no
    parts.push(`Printed as receipt ${String(printed ?? '?')}, recorded as receipt ${String(kept ?? '?')}. Write the new number on the parent's copy if you can.`)
  }
  if (d.flags.includes('gr_renumbered')) {
    parts.push(`GR number ${String(r.typed_gr_no ?? '?')} was already taken, so this pupil was given GR ${String(r.gr_no ?? '?')}.`)
  }
  const newer = Array.isArray(r.kept_newer) ? r.kept_newer.length : 0
  if (newer > 0) {
    parts.push(`${newer} ${newer === 1 ? 'pupil was' : 'pupils were'} left as marked later on another device.`)
  }
  const out = Array.isArray(r.left_out) ? r.left_out.length : 0
  if (out > 0) {
    parts.push(`${out} ${out === 1 ? 'pupil was' : 'pupils were'} left out: no longer on this register or sheet.`)
  }
  // A register or sheet locked meanwhile takes the entry without writing it:
  // the only sign is the screen function's own count of rows it left alone.
  const skipped = REGISTERS_AND_MARKS.has(d.type) ? Number((r as { skipped?: unknown }).skipped ?? 0) : 0
  if (skipped > 0) {
    parts.push(`${skipped} ${skipped === 1 ? 'pupil was' : 'pupils were'} not changed, because the register or sheet is locked`
      + `${newer > 0 ? ' or a later entry was kept' : ''}. To change a locked one, ask the owner or principal to reopen it.`)
  }
  return parts.length ? parts.join(' ') : null
}

export function OfflineWorkPage() {
  const off = useOffline()
  const [discarding, setDiscarding] = useState<OutboxItem | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  if (!off.active || !off.snapshot) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-semibold text-slate-900">Offline work</h1>
        <p className="mt-2 text-sm text-slate-600">
          Work is kept on this device while it is offline for the owner, the principal and teachers.
        </p>
      </div>
    )
  }

  const snap = off.snapshot
  const st = snap.state
  const attention = snap.items.filter((i) => i.status === 'attention')
  const waiting = snap.items.filter((i) => i.status !== 'attention')
  const notices = snap.done.map((d) => ({ d, text: noticeFor(d) })).filter((x) => x.text).slice(0, 20)
  const blocks = st.hello?.receipt_blocks ?? []
  const why = refusalFor(st, st.hello?.role === 'class_teacher' || st.hello?.role === 'subject_teacher'
    ? 'attendance.day' : 'fees.payment', Date.now())

  async function act(id: string, run: () => Promise<unknown>) {
    setBusy(id)
    setError(null)
    try { await run() } catch (e) { setError((e as Error).message) } finally { setBusy(null) }
  }

  return (
    <div className="mx-auto max-w-4xl space-y-6 p-4 sm:p-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold text-slate-900">Offline work</h1>
          <p className="mt-1 text-sm text-slate-600">
            What this device holds for you, and what the school said about what it has taken.
          </p>
        </div>
        <button type="button" onClick={() => void off.syncNow()} disabled={off.syncing || !off.online}
          className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
          {off.syncing ? 'Sending…' : off.online ? 'Sync now' : 'Offline'}
        </button>
      </div>

      {error && <p className="rounded-lg bg-danger-50 px-4 py-2 text-sm text-danger-800">{error}</p>}
      {st.revoked_notice && <p className="rounded-lg bg-danger-50 px-4 py-2 text-sm text-danger-800">{st.revoked_notice}</p>}

      <section className="grid gap-3 rounded-xl border border-slate-200 bg-white p-4 text-sm sm:grid-cols-3">
        <div>
          <div className="text-slate-500">Last synced</div>
          <div className="font-medium text-slate-900">{ago(st.last_sync_wall)}</div>
        </div>
        <div>
          <div className="text-slate-500">Can work offline until</div>
          <div className="font-medium text-slate-900">
            {why ? <span className="font-normal text-danger-700">{why}</span> : fmtDateTime(st.hello?.lease_until ?? null)}
          </div>
        </div>
        {blocks.length > 0 && (
          <div>
            <div className="text-slate-500">Receipt numbers left on this device</div>
            <div className="font-medium text-slate-900">{receiptsLeft(blocks, st.receipt_next)}</div>
          </div>
        )}
        {st.waiting && (
          <p className="sm:col-span-3 text-amber-800">{st.waiting.error}</p>
        )}
      </section>

      <section>
        <h2 className="text-base font-semibold text-slate-900">Needs your attention</h2>
        {attention.length === 0 ? (
          <p className="mt-1 text-sm text-slate-500">Nothing. Everything sent so far was accepted.</p>
        ) : (
          <ul className="mt-2 divide-y divide-slate-200 rounded-xl border border-slate-200 bg-white">
            {attention.map((i) => {
              const a = actionsFor(i)
              return (
                <li key={i.id} className="space-y-2 p-4 text-sm">
                  <div className="flex flex-wrap items-baseline justify-between gap-2">
                    <span className="font-medium text-slate-900">{i.label}</span>
                    <span className="text-xs text-slate-500">{fmtDateTime(i.occurred_at)}</span>
                  </div>
                  <p className="text-danger-800">{i.error}</p>
                  {a.hint && <p className="text-slate-600">{a.hint}</p>}
                  <div className="flex flex-wrap gap-2">
                    {a.resend && (
                      <button type="button" disabled={busy === i.id}
                        onClick={() => void act(i.id, () => off.resend(i.id, a.patch))}
                        className="rounded-lg bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-60">
                        {a.resend}
                      </button>
                    )}
                    <button type="button" disabled={busy === i.id} onClick={() => setDiscarding(i)}
                      className="rounded-lg border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">
                      Discard
                    </button>
                  </div>
                </li>
              )
            })}
          </ul>
        )}
      </section>

      <section>
        <h2 className="text-base font-semibold text-slate-900">Waiting to send</h2>
        {waiting.length === 0 ? (
          <p className="mt-1 text-sm text-slate-500">Nothing waiting.</p>
        ) : (
          <ul className="mt-2 divide-y divide-slate-200 rounded-xl border border-slate-200 bg-white">
            {waiting.map((i) => (
              <li key={i.id} className="flex flex-wrap items-baseline justify-between gap-2 p-3 text-sm">
                <span className="text-slate-900">{i.label}</span>
                <span className="text-xs text-slate-500">
                  {i.status === 'held' ? i.error : `Saved ${fmtDateTime(i.occurred_at)}`}
                </span>
              </li>
            ))}
          </ul>
        )}
        {snap.othersWaiting > 0 && (
          <p className="mt-2 text-sm text-slate-600">
            {snap.othersWaiting} {snap.othersWaiting === 1 ? 'entry' : 'entries'} saved on this computer by another login
            {' '}{snap.othersWaiting === 1 ? 'is' : 'are'} waiting for that person to sign in here again.
          </p>
        )}
      </section>

      {notices.length > 0 && (
        <section>
          <h2 className="text-base font-semibold text-slate-900">Worth knowing</h2>
          <ul className="mt-2 divide-y divide-slate-200 rounded-xl border border-slate-200 bg-white">
            {notices.map(({ d, text }) => (
              <li key={d.id} className="space-y-1 p-3 text-sm">
                <div className="font-medium text-slate-900">{d.label}</div>
                <p className="text-slate-700">{text}</p>
              </li>
            ))}
          </ul>
        </section>
      )}

      {discarding && (
        <AskDialog
          title="Discard this entry?"
          intro={
            discarding.code === 'dependency_discarded' || discarding.code === 'held' ? (
              <span>
                <strong>{discarding.label}</strong> never reached the school, so once it is discarded it is gone.
                Enter it again if it is still needed.
              </span>
            ) : (
              <span>
                <strong>{discarding.label}</strong> will be removed from this device. The school kept what was
                refused, and the owner can still see it there, but nothing here will send it again.
              </span>
            )
          }
          confirmLabel="Discard"
          tone="danger"
          busy={busy === discarding.id}
          onCancel={() => setDiscarding(null)}
          onSubmit={() => {
            const d = discarding
            void act(d.id, () => off.discard(d.id)).then(() => setDiscarding(null))
          }}
        />
      )}
    </div>
  )
}

import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { AskDialog } from '@/components/AskDialog'
import { Button, Card, CardTitle, EmptyState, LoadError, money } from '@/components/ui'
import { fmtDateTime } from '@/lib/format'
import {
  offlineDismiss, offlineReview, revokeDevice,
  schoolDevices, type OfflineReviewItem, type SchoolDevice,
} from '@/offline/server'

/**
 * DEVICES AND OFFLINE WORK, for the owner and principal.
 *
 * Two jobs the server could already do and no screen offered:
 *
 *   * Switching a device off. A lost phone or a teacher who has left keeps a
 *     week of offline working and, for the office, receipt numbers. Switched
 *     off, it may not save anything new; whatever it still holds is handed in
 *     at its next connection and kept here, never applied.
 *   * Seeing offline work the school refused or flagged: from a switched-off
 *     device or login, a receipt printed under a number that was taken, a GR
 *     number given out twice. The device that made it may have let it go, so
 *     this list is where it is not lost.
 */

const PLATFORM: Record<string, string> = {
  android: 'Android app', windows: 'Windows program', web: 'Web browser', other: 'Other',
}

const KIND: Record<string, string> = {
  'attendance.day': 'Daily register',
  'attendance.subject': 'Subject attendance',
  'marks.exam': 'Exam marks',
  'marks.test': 'Test marks',
  'fees.payment': 'Fee payment',
  'fees.family_payment': 'Family payment',
  'expenses.record': 'Expense',
  'students.admit': 'Admission',
}

/** What was sent, in a few words: the money, or how many pupils. */
export function whatWasSent(item: Pick<OfflineReviewItem, 'type' | 'payload'>): string | null {
  const p = item.payload ?? {}
  const amount = Number((p as { amount?: unknown }).amount)
  if (Number.isFinite(amount) && amount > 0) return money(amount)
  const marks = (p as { marks?: unknown }).marks
  if (Array.isArray(marks)) return `${marks.length} ${marks.length === 1 ? 'pupil' : 'pupils'}`
  const name = (p as { admission?: { full_name?: unknown } }).admission?.full_name
  return typeof name === 'string' && name.trim() ? name.trim() : null
}

/** Why it is on this list, in the school's words. */
export function whyListed(item: Pick<OfflineReviewItem, 'status' | 'flags' | 'result' | 'error'>): string {
  if (item.status === 'rejected') return item.error ?? 'Refused.'
  const r = item.result ?? {}
  const parts: string[] = []
  if (item.flags.includes('receipt_renumbered')) {
    parts.push(`Recorded as receipt ${String(r.receipt_no ?? r.admission_receipt_no ?? '?')}, `
      + `but printed as receipt ${String(r.printed_receipt_no ?? '?')}.`)
  }
  if (item.flags.includes('gr_renumbered')) {
    parts.push(`GR ${String(r.typed_gr_no ?? '?')} was taken, so the pupil was given GR ${String(r.gr_no ?? '?')}.`)
  }
  return parts.length ? parts.join(' ') : 'Recorded, with a note for you.'
}

export function OfflineDevices() {
  const qc = useQueryClient()
  const devices = useQuery({ queryKey: ['schoolDevices'], queryFn: schoolDevices })
  const review = useQuery({ queryKey: ['offlineReview'], queryFn: () => offlineReview(false) })
  const [revoking, setRevoking] = useState<SchoolDevice | null>(null)
  const [notice, setNotice] = useState<string | null>(null)

  const revoke = useMutation({
    mutationFn: ({ d, reason }: { d: SchoolDevice; reason: string }) =>
      revokeDevice(d.device_id, d.user_id, reason.trim() || null),
    onSuccess: () => {
      setRevoking(null)
      void qc.invalidateQueries({ queryKey: ['schoolDevices'] })
      void qc.invalidateQueries({ queryKey: ['offlineReview'] })
    },
  })
  const dismiss = useMutation({
    mutationFn: (id: string) => offlineDismiss(id),
    onSuccess: (done) => {
      setNotice(done ? null : 'Only the owner, or a principal who did not send it, can mark this as seen.')
      void qc.invalidateQueries({ queryKey: ['offlineReview'] })
    },
  })

  const live = (devices.data ?? []).filter((d) => !d.revoked_at)
  const off = (devices.data ?? []).filter((d) => d.revoked_at)

  return (
    <div className="space-y-5">
      <LoadError of={[devices, review]} what="Devices and offline work" />

      <Card>
        <CardTitle>Offline work to look at</CardTitle>
        {notice && <p role="status" className="mb-3 text-sm text-due-800">{notice}</p>}
        {review.isLoading ? (
          <p className="text-sm text-slate-500">Loading…</p>
        ) : (review.data ?? []).length === 0 ? (
          <EmptyState title="Nothing to look at"
            message="Offline work the school refused, or recorded with a note, appears here." />
        ) : (
          <ul className="divide-y divide-slate-100">
            {(review.data ?? []).map((item) => (
              <li key={item.id} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-start sm:justify-between">
                <div className="min-w-0 text-sm">
                  <p className="font-medium text-slate-900">
                    {KIND[item.type] ?? item.type}
                    {whatWasSent(item) && <span className="font-normal text-slate-600">, {whatWasSent(item)}</span>}
                  </p>
                  <p className="text-slate-600">
                    {item.name ?? 'Somebody'}, made {fmtDateTime(item.occurred_at)}, received {fmtDateTime(item.received_at)}
                  </p>
                  <p className={item.status === 'rejected' ? 'mt-1 text-danger-800' : 'mt-1 text-slate-700'}>
                    {whyListed(item)}
                  </p>
                </div>
                <Button size="sm" variant="soft" tone="neutral" disabled={dismiss.isPending}
                  onClick={() => dismiss.mutate(item.id)}>
                  Mark as seen
                </Button>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <CardTitle>Devices working offline</CardTitle>
        <p className="mb-3 text-sm text-slate-600">
          Every phone and computer that has worked offline for this school. Switch one off if it is
          lost or its user has left: it can save nothing new, and anything it still holds is handed in
          and kept above, never applied.
        </p>
        {devices.isLoading ? (
          <p className="text-sm text-slate-500">Loading…</p>
        ) : live.length === 0 ? (
          <EmptyState title="No devices yet" message="A device appears here once it has connected to work offline." />
        ) : (
          <ul className="divide-y divide-slate-100">
            {live.map((d) => (
              <li key={`${d.device_id}:${d.user_id}`} className="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0 text-sm">
                  <p className="font-medium text-slate-900">
                    {d.name ?? 'Unknown'}, {PLATFORM[d.platform] ?? d.platform}
                  </p>
                  <p className="text-slate-600">
                    Last connected {fmtDateTime(d.last_seen)}
                    {d.lease_until ? `, may work offline until ${fmtDateTime(d.lease_until)}` : ''}
                    {d.refused > 0 ? `, ${d.refused} refused` : ''}
                  </p>
                </div>
                <Button size="sm" variant="soft" tone="danger" onClick={() => setRevoking(d)}>
                  Switch off
                </Button>
              </li>
            ))}
          </ul>
        )}
        {off.length > 0 && (
          <details className="mt-3 text-sm">
            <summary className="cursor-pointer text-slate-600">Switched off ({off.length})</summary>
            <ul className="mt-2 space-y-1 text-slate-600">
              {off.map((d) => (
                <li key={`${d.device_id}:${d.user_id}`}>
                  {d.name ?? 'Unknown'}, {PLATFORM[d.platform] ?? d.platform}: switched off {fmtDateTime(d.revoked_at)}
                  {d.revoke_reason ? ` (${d.revoke_reason})` : ''}
                </li>
              ))}
            </ul>
          </details>
        )}
      </Card>

      {revoking && (
        <AskDialog
          title="Switch this device off?"
          intro={`${revoking.name ?? 'This person'}'s ${PLATFORM[revoking.platform] ?? 'device'} will save nothing new offline. Anything it still holds is handed in at its next connection and kept here for you, never applied. Its unused receipt numbers are closed.`}
          reason={{ label: 'Why', required: false, placeholder: 'Lost, stolen, or the person has left' }}
          confirmLabel="Switch off"
          tone="danger"
          busy={revoke.isPending}
          error={revoke.error ? (revoke.error as Error).message : null}
          onCancel={() => { setRevoking(null); revoke.reset() }}
          onSubmit={({ reason }) => revoke.mutate({ d: revoking, reason })}
        />
      )}
    </div>
  )
}

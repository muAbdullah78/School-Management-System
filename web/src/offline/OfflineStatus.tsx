// The bar under the banners that says how offline work stands. Silent when
// there is nothing to say: online, nothing waiting, nothing to look at.
import { Link } from 'react-router-dom'
import { useOffline } from './OfflineProvider'

/** "just now", "5 minutes ago", "2 hours ago", "3 days ago". */
export function ago(wall: number | null, now = Date.now()): string {
  if (wall == null) return 'never'
  const m = Math.max(0, Math.floor((now - wall) / 60_000))
  if (m < 1) return 'just now'
  if (m < 60) return `${m} minute${m === 1 ? '' : 's'} ago`
  const h = Math.floor(m / 60)
  if (h < 48) return `${h} hour${h === 1 ? '' : 's'} ago`
  const d = Math.floor(h / 24)
  return `${d} day${d === 1 ? '' : 's'} ago`
}

/** Hours of offline working left on the lease, rounded down, or null. */
export function hoursLeft(leaseUntil: string | null | undefined, serverNowMs: number): number | null {
  if (!leaseUntil) return null
  return Math.floor((Date.parse(leaseUntil) - serverNowMs) / 3_600_000)
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`
}

export function OfflineStatus() {
  const off = useOffline()
  const snap = off.snapshot
  if (!off.active || !snap) {
    return off.online ? null : (
      <div className="px-6 py-2 text-sm bg-slate-800 text-slate-100 print:hidden">
        <span className="font-medium">Offline.</span> Showing what was last loaded.
      </div>
    )
  }

  const waiting = snap.pending + snap.held + off.legacyWaiting
  const st = snap.state
  const left = hoursLeft(st.hello?.lease_until, Date.now() + st.clock.offset_ms)
  const notice = st.revoked_notice
  const stopped = st.stopped
  const held = st.waiting

  const nothingToSay = off.online && waiting === 0 && snap.attention === 0 && !notice && !stopped && !held
  if (nothingToSay) return null

  const dark = !off.online
  return (
    <div
      role="status"
      className={`flex flex-wrap items-center gap-x-3 gap-y-1 px-6 py-2 text-sm print:hidden ${
        dark ? 'bg-slate-800 text-slate-100' : snap.attention > 0 || stopped ? 'bg-danger-50 text-danger-800' : 'bg-amber-50 text-amber-800'}`}
    >
      {!off.online && <span className="font-medium">Offline.</span>}
      {notice ? (
        <span>{notice}</span>
      ) : stopped ? (
        <span>{stopped}</span>
      ) : (
        <>
          {waiting > 0 && (
            <span>
              {plural(waiting, 'entry', 'entries')} saved on this device {off.online ? 'waiting to send' : 'will be sent when the connection returns'}.
            </span>
          )}
          {snap.attention > 0 && <span className="font-medium">{plural(snap.attention, 'entry needs', 'entries need')} your attention.</span>}
          {held && off.online && <span>{held.error}</span>}
          {!off.online && waiting === 0 && snap.attention === 0 && <span>Work you save is kept on this device and sent later.</span>}
          {!off.online && left != null && left < 24 && left >= 0 && (
            <span className="font-medium">Connect within {plural(left, 'hour', 'hours')} to keep working offline.</span>
          )}
          <span className="opacity-80">Last synced {ago(st.last_sync_wall)}.</span>
        </>
      )}
      <span className="ml-auto flex items-center gap-2">
        <Link to="/offline" className="underline underline-offset-2">Offline work</Link>
        {notice && (
          <button type="button" onClick={() => void off.clearRevokedNotice()}
            className="rounded px-2 py-0.5 text-xs font-medium underline">Dismiss</button>
        )}
        {off.online && !notice && (
          <button type="button" onClick={() => void off.syncNow()} disabled={off.syncing}
            className="rounded bg-amber-600 px-3 py-1 text-xs font-medium text-white hover:bg-amber-700 disabled:opacity-60">
            {off.syncing ? 'Sending…' : 'Sync now'}
          </button>
        )}
      </span>
    </div>
  )
}

import { useEffect, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { getQueue, subscribe, flushQueue, countMarks, type PendingAttendance } from '@/lib/offlineQueue'

/** App-wide connectivity + pending-sync banner. Hidden when online with an empty
 *  queue; otherwise shows offline state and any attendance waiting to sync, and
 *  flushes automatically when the connection returns. */
export function OfflineIndicator() {
  const qc = useQueryClient()
  const [online, setOnline] = useState(() => (typeof navigator === 'undefined' ? true : navigator.onLine))
  const [queue, setQueue] = useState<PendingAttendance[]>(getQueue())
  const [syncing, setSyncing] = useState(false)

  async function doSync() {
    if (getQueue().length === 0) return
    setSyncing(true)
    try {
      await flushQueue()
      qc.invalidateQueries({ queryKey: ['roster'] })
    } finally {
      setSyncing(false)
      setQueue(getQueue())
    }
  }

  useEffect(() => {
    const refresh = () => setQueue(getQueue())
    const unsub = subscribe(refresh)
    const goOnline = () => { setOnline(true); void doSync() }
    const goOffline = () => setOnline(false)
    window.addEventListener('online', goOnline)
    window.addEventListener('offline', goOffline)
    if ((typeof navigator === 'undefined' ? true : navigator.onLine) && getQueue().length) void doSync()
    return () => {
      unsub()
      window.removeEventListener('online', goOnline)
      window.removeEventListener('offline', goOffline)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const batches = queue.length
  if (online && batches === 0) return null
  const marks = countMarks(queue)

  return (
    <div className={`flex flex-wrap items-center gap-2 px-6 py-2 text-sm ${online ? 'bg-amber-50 text-amber-800' : 'bg-slate-800 text-slate-100'}`}>
      {!online && <span className="font-medium">● Offline</span>}
      {batches > 0 ? (
        <span>
          {marks} attendance mark{marks === 1 ? '' : 's'} across {batches} class{batches === 1 ? '' : 'es'} waiting to sync.
        </span>
      ) : (
        <span>You’re offline. Attendance you save will sync automatically when the connection returns.</span>
      )}
      {online && batches > 0 && (
        <button onClick={() => void doSync()} disabled={syncing}
          className="ml-auto rounded bg-amber-600 px-3 py-1 text-xs font-medium text-white hover:bg-amber-700 disabled:opacity-60">
          {syncing ? 'Syncing…' : 'Sync now'}
        </button>
      )}
    </div>
  )
}

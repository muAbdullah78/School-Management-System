// Runs the offline engine for whoever is signed in, and tells the screens how
// offline work stands.
//
// Syncs when the app opens, when the connection comes back, when the app comes
// back to the front, every minute while it is online and showing, after
// anything is saved, and from "Sync now". The engine makes sure only one tab
// does it at a time; the others hear about it and redraw.
//
// Writers only for now (owner, principal and teachers). Parents and the
// observer read; their offline copies are chunk 3. A vendor support visit has
// no profile and never works offline.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { OfflineEngine, type NewWork, type Snapshot, type SyncReport } from './engine'
import { OfflineStore, type OutboxItem, type UserRef } from './store'
import { deviceId, platform } from './device'
import { legacyQueue } from './legacy'
import { getQueue, ownedBy, subscribe as subscribeLegacy } from '@/lib/offlineQueue'

const WRITERS = new Set(['owner', 'principal', 'class_teacher', 'subject_teacher'])
const EVERY_MS = 60_000

export interface OfflineState {
  /** The engine is running for this login. */
  active: boolean
  online: boolean
  syncing: boolean
  snapshot: Snapshot | null
  /** Registers the attendance screen queued the old way (before 0157), not yet moved into the outbox. */
  legacyWaiting: number
  lastReport: SyncReport | null
  syncNow: () => Promise<SyncReport | null>
  /** Save work as a command, and send it straight away if there is a connection. */
  submit: (work: NewWork) => Promise<OutboxItem>
  resend: (id: string, patch?: Record<string, unknown>) => Promise<string>
  discard: (id: string) => Promise<void>
  clearRevokedNotice: () => Promise<void>
}

const inactive: OfflineState = {
  active: false, online: true, syncing: false, snapshot: null, legacyWaiting: 0, lastReport: null,
  syncNow: async () => null,
  submit: async () => { throw new Error('Offline work is not available here.') },
  resend: async () => { throw new Error('Offline work is not available here.') },
  discard: async () => undefined,
  clearRevokedNotice: async () => undefined,
}

const Ctx = createContext<OfflineState>(inactive)

/** For tests that draw a screen as if offline work stood a certain way. */
export const OfflineContext = Ctx

export function useOffline(): OfflineState {
  return useContext(Ctx)
}

let shared: OfflineEngine | null = null
function engine(): OfflineEngine | null {
  if (typeof indexedDB === 'undefined') return null
  shared ??= new OfflineEngine({
    store: new OfflineStore(), deviceId: deviceId(), platform: platform(), legacy: legacyQueue,
  })
  return shared
}

function isOnline(): boolean {
  return typeof navigator === 'undefined' ? true : navigator.onLine !== false
}

export function OfflineProvider({ children }: { children: ReactNode }) {
  const { profile, session } = useAuth()
  const qc = useQueryClient()
  const eng = useMemo(() => engine(), [])
  const user: UserRef | null = useMemo(() => (
    eng && session && profile && WRITERS.has(profile.role) && profile.school_id
      ? { userId: profile.id, schoolId: profile.school_id } : null
  ), [eng, session, profile])

  const [online, setOnline] = useState(isOnline())
  const [syncing, setSyncing] = useState(false)
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const [lastReport, setLastReport] = useState<SyncReport | null>(null)
  const [legacyWaiting, setLegacyWaiting] = useState(0)
  const running = useRef<Promise<SyncReport | null> | null>(null)
  const userRef = useRef(user)
  userRef.current = user

  const refresh = useCallback(async () => {
    const u = userRef.current
    if (!eng || !u) { setSnapshot(null); return }
    try {
      const snap = await eng.snapshot(u)
      if (userRef.current === u) setSnapshot(snap)
    } catch { /* storage unavailable: nothing to show */ }
  }, [eng])

  const syncNow = useCallback(async (): Promise<SyncReport | null> => {
    const u = userRef.current
    if (!eng || !u) return null
    if (running.current) return running.current
    const run = (async () => {
      setSyncing(true)
      try {
        const report = await eng.sync(u)
        setLastReport(report)
        // Something the screens show has changed on the server.
        if (report.applied > 0) void qc.invalidateQueries()
        return report
      } catch (e) {
        const report: SyncReport = { skipped: false, reached: false, applied: 0, rejected: 0, waiting: null,
          error: (e as Error)?.message ?? String(e) }
        setLastReport(report)
        return report
      } finally {
        setSyncing(false)
        running.current = null
        void refresh()
      }
    })()
    running.current = run
    return run
  }, [eng, qc, refresh])

  // Redraw on any change, here or in another tab.
  useEffect(() => {
    if (!eng) return
    void refresh()
    return eng.subscribe(() => { void refresh() })
  }, [eng, refresh, user])

  // The old attendance queue, counted until the engine moves it in.
  useEffect(() => {
    if (!user) { setLegacyWaiting(0); return }
    const count = () => setLegacyWaiting(ownedBy(getQueue(), user.schoolId).length)
    count()
    return subscribeLegacy(count)
  }, [user])

  // When to sync.
  useEffect(() => {
    if (!user) return
    const tryNow = () => { if (isOnline()) void syncNow() }
    const goOnline = () => { setOnline(true); tryNow() }
    const goOffline = () => setOnline(false)
    const onShow = () => { if (document.visibilityState === 'visible') tryNow() }
    window.addEventListener('online', goOnline)
    window.addEventListener('offline', goOffline)
    document.addEventListener('visibilitychange', onShow)
    const timer = window.setInterval(() => {
      if (document.visibilityState === 'visible') tryNow()
    }, EVERY_MS)
    tryNow()
    return () => {
      window.removeEventListener('online', goOnline)
      window.removeEventListener('offline', goOffline)
      document.removeEventListener('visibilitychange', onShow)
      window.clearInterval(timer)
    }
  }, [user, syncNow])

  const submit = useCallback(async (work: NewWork) => {
    const u = userRef.current
    if (!eng || !u) throw new Error('Offline work is not available for this login.')
    const item = await eng.enqueue(u, work)
    if (isOnline()) void syncNow()
    return item
  }, [eng, syncNow])

  const resend = useCallback(async (id: string, patch?: Record<string, unknown>) => {
    const u = userRef.current
    if (!eng || !u) throw new Error('Offline work is not available for this login.')
    const fresh = await eng.resend(u, id, patch)
    if (isOnline()) void syncNow()
    return fresh
  }, [eng, syncNow])

  const discard = useCallback(async (id: string) => {
    const u = userRef.current
    if (eng && u) await eng.discard(u, id)
  }, [eng])

  const clearRevokedNotice = useCallback(async () => {
    const u = userRef.current
    if (eng && u) await eng.clearRevokedNotice(u)
  }, [eng])

  const value = useMemo<OfflineState>(() => (user ? {
    active: true, online, syncing, snapshot, legacyWaiting, lastReport, syncNow, submit, resend, discard, clearRevokedNotice,
  } : { ...inactive, online }),
  [user, online, syncing, snapshot, legacyWaiting, lastReport, syncNow, submit, resend, discard, clearRevokedNotice])

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

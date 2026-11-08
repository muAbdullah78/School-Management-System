// Runs the offline engine for whoever is signed in, and tells the screens how
// offline work stands.
//
// Syncs when the app opens, when the connection comes back, when the app comes
// back to the front, every minute while it is online and showing, after
// anything is saved, and from "Sync now". The engine makes sure only one tab
// does it at a time; the others hear about it and redraw.
//
// The engine runs for those who write (owner, principal and teachers). Every
// login, parents and the observer included, gets the offline copies of what it
// reads (readCache.ts), and its role's pack is fetched ahead of time: after
// each sync for a writer, every 15 minutes for a reader. A vendor support visit
// has no profile and never works offline.
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { OfflineEngine, type NewWork, type Snapshot, type SyncReport } from './engine'
import { OfflineStore, type OutboxItem, type UserRef } from './store'
import { deviceId, platform } from './device'
import { legacyQueue } from './legacy'
import { getQueue, ownedBy, subscribe as subscribeLegacy } from '@/lib/offlineQueue'
import { onServedFromCopy } from './readCache'
import { warmPacks } from './packs'
import { readStore } from '@/lib/supabase'

const WRITERS = new Set(['owner', 'principal', 'class_teacher', 'subject_teacher'])
const READERS = new Set(['parent', 'readonly'])
const EVERY_MS = 60_000
const READER_EVERY_MS = 15 * 60_000
/** A writer's pack is fetched again at most this often, however often it syncs. */
const WARM_EVERY_MS = 15 * 60_000

/** Where a saved command has got to. */
export type Settled =
  | { status: 'applied'; result: Record<string, unknown> | null; flags: string[] }
  | { status: 'attention'; code: string | null; error: string | null }
  | { status: 'pending' }
/** How long after a copy was shown the bar keeps saying so. */
const COPY_NOTICE_MS = 2 * 60_000

export interface OfflineState {
  /** The engine is running for this login. */
  active: boolean
  online: boolean
  syncing: boolean
  snapshot: Snapshot | null
  /** Registers the attendance screen queued the old way (before 0157), not yet moved into the outbox. */
  legacyWaiting: number
  lastReport: SyncReport | null
  /** When the copy a screen was last shown (instead of a fresh answer) was saved, if that was in the last two minutes. */
  copySavedAt: number | null
  syncNow: () => Promise<SyncReport | null>
  /** Save work as a command, and send it straight away if there is a connection. */
  submit: (work: NewWork) => Promise<OutboxItem>
  /** Wait up to `ms` for a saved command to be applied or refused; 'pending' if it has not reached the school. */
  settle: (id: string, ms: number) => Promise<Settled>
  resend: (id: string, patch?: Record<string, unknown>) => Promise<string>
  discard: (id: string) => Promise<void>
  clearRevokedNotice: () => Promise<void>
}

const inactive: OfflineState = {
  active: false, online: true, syncing: false, snapshot: null, legacyWaiting: 0, lastReport: null, copySavedAt: null,
  syncNow: async () => null,
  submit: async () => { throw new Error('Offline work is not available here.') },
  settle: async () => ({ status: 'pending' }),
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
  // A login the school has switched off can no longer read its own profile,
  // so it would never say hello again and its unsent work (fees with receipts
  // already in parents' hands) would stay on this device for ever. If this
  // device holds work for it, the engine runs for it once more: the hello
  // answers "switched off", and the work is handed to the school for the owner.
  const [handIn, setHandIn] = useState<UserRef | null>(null)
  useEffect(() => {
    if (!eng || !session || profile) { setHandIn(null); return }
    let live = true
    void eng.heldFor(session.user.id).then((u) => { if (live) setHandIn(u) }, () => undefined)
    return () => { live = false }
  }, [eng, session, profile])
  const user: UserRef | null = useMemo(() => (
    eng && session && profile && WRITERS.has(profile.role) && profile.school_id
      ? { userId: profile.id, schoolId: profile.school_id } : handIn
  ), [eng, session, profile, handIn])

  const [online, setOnline] = useState(isOnline())
  const [syncing, setSyncing] = useState(false)
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const [lastReport, setLastReport] = useState<SyncReport | null>(null)
  const [legacyWaiting, setLegacyWaiting] = useState(0)
  const [copySavedAt, setCopySavedAt] = useState<number | null>(null)
  const running = useRef<Promise<SyncReport | null> | null>(null)
  const userRef = useRef(user)
  userRef.current = user
  const role = profile?.role ?? null
  const roleRef = useRef(role)
  roleRef.current = role
  const lastWarm = useRef(0)

  // A screen shown a copy instead of a fresh answer: say how old it is, for a
  // while. Copies older than 30 days are thrown away once per session.
  useEffect(() => {
    let clear: number | undefined
    const off = onServedFromCopy(({ saved_wall }) => {
      setCopySavedAt((cur) => (cur == null ? saved_wall : Math.min(cur, saved_wall)))
      window.clearTimeout(clear)
      clear = window.setTimeout(() => setCopySavedAt(null), COPY_NOTICE_MS)
    })
    void readStore?.prune(Date.now()).catch(() => undefined)
    return () => { off(); window.clearTimeout(clear) }
  }, [])

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
        const r = roleRef.current
        // The pack is fetched again only every fifteen minutes: a counter taking
        // a payment a minute must not fetch the whole pupil list each time.
        const warm = r && Date.now() - lastWarm.current > WARM_EVERY_MS
          ? async () => { await warmPacks(r); lastWarm.current = Date.now() } : undefined
        const report = await eng.sync(u, warm)
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

  // A reader (a parent, the observer) has nothing to send, but its pack is
  // fetched ahead of time all the same, so the portal opens with no signal.
  useEffect(() => {
    if (!session || !role || !READERS.has(role)) return
    const warm = () => { if (isOnline() && document.visibilityState === 'visible') void warmPacks(role).catch(() => undefined) }
    warm()
    window.addEventListener('online', warm)
    const timer = window.setInterval(warm, READER_EVERY_MS)
    return () => { window.removeEventListener('online', warm); window.clearInterval(timer) }
  }, [session, role])

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

  const settle = useCallback(async (id: string, ms: number): Promise<Settled> => {
    const u = userRef.current
    if (!eng || !u) return { status: 'pending' }
    const until = Date.now() + ms
    // A sync already running may have started before this was saved: one more
    // after it carries it. Raced against the deadline: on a weak signal two
    // whole syncs (the outbox, the copies) used to keep a parent at the window
    // for a minute, however short the wait was meant to be.
    if (isOnline()) {
      await Promise.race([
        (async () => { await syncNow(); await syncNow() })(),
        new Promise<void>((r) => setTimeout(r, Math.max(0, until - Date.now()))),
      ])
    }
    for (;;) {
      const snap = await eng.snapshot(u)
      const it = snap.items.find((i) => i.id === id)
      if (!it) {
        const d = snap.done.find((x) => x.id === id)
        if (d) return { status: 'applied', result: d.result, flags: d.flags }
        // Handed in when the school switched this device or login off: the
        // server kept it as refused, and this device has forgotten it.
        if (snap.state.handed_in?.includes(id)) {
          const login = snap.state.hello?.login_off === true
          return {
            status: 'attention', code: login ? 'login_off' : 'device_revoked',
            error: `This ${login ? 'login' : 'device'} was switched off by the school, so this was not saved. `
              + 'The owner can see it under offline work.',
          }
        }
        return { status: 'pending' }
      }
      if (it.status === 'attention') return { status: 'attention', code: it.code, error: it.error }
      if (Date.now() >= until || !isOnline()) return { status: 'pending' }
      await new Promise((r) => setTimeout(r, 500))
    }
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
    active: true, online, syncing, snapshot, legacyWaiting, lastReport, copySavedAt, syncNow, submit, settle, resend,
    discard, clearRevokedNotice,
  } : { ...inactive, online, copySavedAt }),
  [user, online, syncing, snapshot, legacyWaiting, lastReport, copySavedAt, syncNow, submit, settle, resend, discard,
    clearRevokedNotice])

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

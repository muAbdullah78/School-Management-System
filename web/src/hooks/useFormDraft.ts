import { useCallback, useEffect, useRef, useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'

/**
 * A form that remembers what you had typed.
 *
 * WHAT THIS IS FOR
 *
 * Losing a half-filled form is the most expensive small failure a school
 * office has, because the data is not in the operator's head: it is on a
 * birth certificate, a CNIC and a previous school's leaving certificate spread
 * across the desk. Retyping it is five minutes and a fresh chance to mistype a
 * date of birth that will be printed on a certificate in nine years' time.
 *
 * The specific crash that prompted this is fixed at its source (AuthProvider
 * and the three latched gates), but that was only ONE way to lose a form. The
 * others are not bugs and cannot be fixed: the browser reloads the tab to
 * reclaim memory on a 2GB Android phone, somebody presses F5, the office power
 * goes and the UPS does not, a teacher taps a link in WhatsApp and comes back.
 * The only answer that covers all of them is to write the draft down.
 *
 * WHY sessionStorage AND NOT localStorage
 *
 * These machines are shared. One desktop in the office is used by whoever is
 * sitting at it, and school computers are very often not signed out. A draft
 * in localStorage survives the browser closing, so a half-typed admission
 * containing a child's name, father's name and date of birth would sit on that
 * disk until something cleared it, and would be handed to the next person to
 * open the same form. sessionStorage is scoped to the TAB: it survives a
 * refresh, a crash-restore and any amount of tab switching, and it is gone when
 * the tab is closed. That is exactly the window in which a draft is wanted and
 * no longer.
 *
 * It is ALSO keyed by user id, so signing out and in as somebody else on the
 * same machine and the same tab does not hand over the previous person's work.
 *
 * WHAT MUST NEVER BE PUT IN HERE. Passwords, and anything that is not JSON: a
 * File from a photo input serialises to {} and would silently restore as an
 * empty object that looks like a chosen file. Pass plain fields only.
 */

/** Bumped when the SHAPE of a stored draft changes in a way that would restore badly. */
const VERSION = 1

/**
 * How long a draft is worth restoring.
 *
 * A tab left open overnight and returned to in the morning is a different piece
 * of work, and silently refilling yesterday's half-finished admission is worse
 * than an empty form: the operator does not know which fields they typed and
 * which the machine did. Twelve hours covers a school day with room to spare.
 */
const MAX_AGE_MS = 12 * 60 * 60 * 1000

type Stored<T> = { v: number; at: number; data: T }

/**
 * Whether the form currently holds nothing worth keeping.
 *
 * JSON.stringify is key-order sensitive, and both objects here are built by
 * spreading the same literal, so their key order matches. The fallback on a
 * throw is `false` (treat it as worth keeping): losing a draft is the failure
 * this file exists to prevent, so ambiguity resolves towards saving it.
 */
function isEmptyForm<T extends object>(value: T, empty: T): boolean {
  if (value === empty) return true
  try {
    return JSON.stringify(value) === JSON.stringify(empty)
  } catch {
    return false
  }
}

function read<T>(key: string): T | null {
  try {
    const raw = sessionStorage.getItem(key)
    if (!raw) return null
    const parsed = JSON.parse(raw) as Stored<T>
    if (!parsed || parsed.v !== VERSION) return null
    if (typeof parsed.at !== 'number' || Date.now() - parsed.at > MAX_AGE_MS) return null
    return parsed.data ?? null
  } catch {
    // Private browsing, disabled storage, a quota error, or somebody else's
    // JSON under our key. A draft is a convenience; never break the form for it.
    return null
  }
}

function write<T>(key: string, data: T): void {
  try {
    sessionStorage.setItem(key, JSON.stringify({ v: VERSION, at: Date.now(), data } as Stored<T>))
  } catch {
    /* full, blocked, or unavailable. Nothing to do and nothing worth saying. */
  }
}

function drop(key: string): void {
  try {
    sessionStorage.removeItem(key)
  } catch {
    /* as above */
  }
}

export interface FormDraft<T> {
  /** The live form values. Use exactly as you would useState's value. */
  value: T
  /** Merge a few fields. The common case: `set({ father_name: e.target.value })`. */
  set: (patch: Partial<T>) => void
  /** Replace the whole object, or map the previous one. */
  replace: (next: T | ((prev: T) => T)) => void
  /** Wipe the draft AND reset the form. Call this after a successful save. */
  clear: () => void
  /**
   * True when this mount restored something previously typed, so the screen can
   * say so. A form that silently refills itself is unsettling; one that says
   * "we kept what you had typed" and offers to discard it is not.
   */
  restored: boolean
}

/**
 * @param name  Stable identifier for this form, e.g. 'admission'. Scoped per
 *              user automatically. If one screen holds two independent forms,
 *              give them different names.
 * @param initial The empty form. Must be a plain JSON-safe object.
 */
export function useFormDraft<T extends object>(name: string, initial: T): FormDraft<T> {
  const { profile, session } = useAuth()
  // profile.id is the same value as the auth user id, but profile can be null
  // for a split second after sign-in and for platform admins, so fall back.
  const who = profile?.id ?? session?.user?.id ?? 'anon'
  const key = `smsdraft:${VERSION}:${who}:${name}`

  // The initial object is usually written inline at the call site, so it is a
  // new object on every render. Held in a ref so `clear()` can reset to it
  // without the caller having to memoise anything.
  //
  // It is captured on the FIRST render and never updated. A caller whose empty
  // form depends on loaded data (a default class, say) must therefore not rely
  // on this hook to notice: pass a constant empty form and apply the default
  // separately.
  const emptyRef = useRef(initial)

  // Read ONCE, not once per useState initialiser. Two reads of the same key
  // could disagree if another tab wrote between them, which would show the
  // "we kept what you had typed" notice over a form that restored nothing.
  const firstRead = useRef<T | null | undefined>(undefined)
  if (firstRead.current === undefined) firstRead.current = read<T>(key)

  const [value, setValue] = useState<T>(() => {
    const saved = firstRead.current
    // Spread over the empty form rather than using the stored object directly:
    // a field added to the form since the draft was written must appear with
    // its proper default, not as undefined.
    return saved ? { ...initial, ...saved } : initial
  })

  const [restored, setRestored] = useState(() => firstRead.current !== null)

  /*
   * The key can change under us: the profile arrives a tick after sign-in, so
   * `who` goes from the auth id (or 'anon') to the profile id. Re-read on that
   * change rather than stranding the draft under the old key.
   *
   * Deliberately NOT writing here. An effect that wrote on key change would
   * copy an empty form over a real draft on the very first render after a
   * remount, which is the failure this hook exists to prevent.
   */
  const lastKey = useRef(key)
  useEffect(() => {
    if (lastKey.current === key) return
    lastKey.current = key
    const saved = read<T>(key)
    if (saved) {
      setValue((prev) => ({ ...prev, ...saved }))
      setRestored(true)
    }
  }, [key])

  /*
   * Written on a short timer rather than on every keystroke.
   *
   * sessionStorage.setItem is synchronous and blocks the main thread, and these
   * forms are typed into on cheap Android phones. 400ms is long enough that a
   * normal typing burst writes once, and short enough that no realistic way of
   * losing the tab beats it.
   */
  useEffect(() => {
    const t = setTimeout(() => {
      // An EMPTY form is not a draft, and storing one is not harmless. After a
      // successful save this hook resets `value` to the empty object; writing
      // that back would leave a draft on disk whose only effect is to show
      // "we kept what you had typed" over a blank form the next time the screen
      // is opened. Deleting is the honest write.
      //
      // Compared by value, not by reference, so a form the user typed into and
      // then cleared out by hand is treated the same as one never touched.
      if (isEmptyForm(value, emptyRef.current)) drop(key)
      else write(key, value)
    }, 400)
    return () => clearTimeout(t)
  }, [key, value])

  const set = useCallback((patch: Partial<T>) => {
    setValue((prev) => ({ ...prev, ...patch }))
  }, [])

  const replace = useCallback((next: T | ((prev: T) => T)) => {
    setValue((prev) => (typeof next === 'function' ? (next as (p: T) => T)(prev) : next))
  }, [])

  const clear = useCallback(() => {
    drop(key)
    setValue(emptyRef.current)
    setRestored(false)
  }, [key])

  return { value, set, replace, clear, restored }
}

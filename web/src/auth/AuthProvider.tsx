import {
  createContext,
  useContext,
  useEffect,
  useReducer,
  useRef,
  useState,
  type ReactNode,
} from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { cacheSchoolId } from '@/lib/offlineQueue'
import type { Role } from './roles'
import { gateIsLoading, initialGate, reduceGate } from './authGate'

export interface Profile {
  id: string
  full_name: string | null
  role: Role
  staff_id: string | null
  school_id: string
}

interface AuthState {
  session: Session | null
  profile: Profile | null
  loading: boolean
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signOut: () => Promise<void>
  /** Send a reset link. See the note on sendReset below for why it never says
   *  whether the address exists. */
  sendReset: (email: string) => Promise<{ error: string | null }>
  setPassword: (password: string) => Promise<{ error: string | null }>
}

/**
 * Exported so the rendering harnesses in web/tools/ can supply a signed-in
 * profile without a Supabase client.
 *
 * They render real PAGES — not just printables — to check layout and to capture
 * the screenshots that go in the user guide, and every page calls useAuth(),
 * which throws outside a provider. Rendering the real <AuthProvider> is not an
 * option: with no client it settles on profile = null, so every page would
 * render its signed-out state.
 *
 * Exporting the context rather than adding a test-only provider keeps exactly one
 * implementation of the real thing.
 */
export const AuthContext = createContext<AuthState | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  /*
   * The gate is a reducer in ./authGate.ts, not a pile of flags here, because
   * the bug it fixes was an ORDERING bug and ordering is what a reducer makes
   * testable. This project has no jsdom and its rendering harness fires no
   * effects, so a flag set in the wrong effect is invisible to every test it
   * can run. authGate.test.ts plays the exact cold-start sequence that used to
   * redirect a signed-in clerk to /login on every launch of the desktop app.
   */
  const [gate, dispatch] = useReducer(reduceGate, initialGate)
  const [profile, setProfile] = useState<Profile | null>(null)

  /*
   * Once onAuthStateChange has spoken, a late getSession() result is STALE and
   * must be dropped.
   *
   * signInWithPassword fires auth-change immediately, while getSession() may
   * still be resolving against a snapshot taken before the sign-in. Applying
   * that answer would sign the user out one tick after they signed in. Asserted
   * in authGate.test.ts as a hazard the call site owns, which is here.
   */
  const authChangeSeen = useRef(false)

  useEffect(() => {
    if (!supabase) {
      dispatch({ type: 'no-client' })
      return
    }
    let active = true

    // Subscribed BEFORE getSession() is called, so a change that happens during
    // the restore cannot be missed in the gap between them.
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      authChangeSeen.current = true
      dispatch({ type: 'auth-change', session: s })
    })

    supabase.auth
      .getSession()
      .then(({ data }) => {
        if (!active || authChangeSeen.current) return
        dispatch({ type: 'restored', session: data.session })
      })
      // A THROW HERE USED TO BE UNHANDLED. getSession() refreshes an expired
      // token, which is a network call, so offline it can reject. Unhandled,
      // the gate never opened and the app sat on "Loading" with no way past it.
      .catch(() => {
        if (active) dispatch({ type: 'restore-failed' })
      })

    // The floor. If neither path ever settles, the user gets the sign-in screen
    // rather than a spinner with no end. Ten seconds, because a slow school
    // connection refreshing a token is normal and a permanent spinner is not.
    const watchdog = setTimeout(() => {
      if (active) dispatch({ type: 'watchdog' })
    }, 10000)

    return () => {
      active = false
      clearTimeout(watchdog)
      sub.subscription.unsubscribe()
    }
  }, [])

  const session = gate.session

  // Load the user's profile (role) whenever the session changes.
  useEffect(() => {
    if (!supabase) return
    const userId = session?.user?.id
    if (!userId) {
      setProfile(null)
      dispatch({ type: 'profile-settled' })
      return
    }
    let active = true
    dispatch({ type: 'profile-loading' })
    supabase
      .from('profiles')
      .select('id, full_name, role, staff_id, school_id')
      .eq('id', userId)
      // maybeSingle, not single: a PLATFORM admin has no profile at all (they
      // belong to no school), and .single() treats that as an error, which
      // would leave them stuck on a loading screen they can never get past.
      .maybeSingle()
      // TWO ARGUMENTS, not .then().catch(): the query builder resolves to a
      // PromiseLike, which has then and no catch, so the chained form does not
      // typecheck. Both paths must settle the gate. Same reasoning as the
      // restore above: a failed profile fetch is a reason to carry on with no
      // profile, and never a reason to hang on a spinner.
      .then(
        ({ data }) => {
          if (!active) return
          const p = (data as Profile) ?? null
          setProfile(p)
          // Cached so work queued while OFFLINE can still be stamped with the
          // school it belongs to: there is no server to ask at that moment.
          cacheSchoolId(p?.school_id ?? null)
          dispatch({ type: 'profile-settled' })
        },
        () => {
          if (active) dispatch({ type: 'profile-settled' })
        },
      )
    return () => {
      active = false
    }
  }, [session])

  const loading = gateIsLoading(gate)

  async function signIn(email: string, password: string) {
    if (!supabase) return { error: 'App is not configured.' }
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return { error: error?.message ?? null }
  }

  async function signOut() {
    if (!supabase) return
    await supabase.auth.signOut()
    setProfile(null)
  }

  /**
   * Send a password reset link.
   *
   * WHY THIS EXISTS AT ALL. There was no way back into this software for anyone
   * who forgot a password — not a principal, not a clerk, not a parent. The only
   * remedy was to ask the vendor to reset it by hand, which means the vendor
   * setting a password for a school's owner and telling it to them over
   * WhatsApp. For a product sold to fifty schools that is not a support burden,
   * it is a security posture.
   *
   * IT NEVER SAYS WHETHER THE ADDRESS EXISTS. The screen shows the same sentence
   * for a real account, a typo and a stranger fishing for whether a particular
   * teacher works at a particular school. Supabase behaves this way too, so all
   * this does is refuse to leak what the API already refuses to leak.
   *
   * redirectTo must ALSO be listed under Authentication → URL Configuration in
   * Supabase, or the link in the email lands on the site root with the token
   * stripped and the parent sees a login screen and no explanation.
   */
  async function sendReset(email: string) {
    if (!supabase) return { error: 'App is not configured.' }
    const { error } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset`,
    })
    // Reported only when the request itself failed — no network, or the address
    // is rate-limited. Not "no such user", which this must not disclose.
    return { error: error?.message ?? null }
  }

  /**
   * Set a new password for whoever is signed in.
   *
   * Used from two places: the recovery link, and (later) a change-password
   * screen. Supabase enforces its own minimum length server-side; the caller
   * checks the two boxes match, because "your passwords do not match" told after
   * a round trip is a worse experience than told immediately.
   */
  async function setPassword(password: string) {
    if (!supabase) return { error: 'App is not configured.' }
    const { error } = await supabase.auth.updateUser({ password })
    return { error: error?.message ?? null }
  }

  return (
    <AuthContext.Provider
      value={{ session, profile, loading, signIn, signOut, sendReset, setPassword }}
    >
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within <AuthProvider>')
  return ctx
}

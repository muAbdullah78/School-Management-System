import { createContext, useContext, useEffect, useState, type ReactNode } from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { cacheSchoolId } from '@/lib/offlineQueue'
import type { Role } from './roles'

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

const AuthContext = createContext<AuthState | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [profile, setProfile] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (!supabase) {
      setLoading(false)
      return
    }
    let active = true

    supabase.auth.getSession().then(({ data }) => {
      if (!active) return
      setSession(data.session)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s)
    })

    return () => {
      active = false
      sub.subscription.unsubscribe()
    }
  }, [])

  // Load the user's profile (role) whenever the session changes.
  useEffect(() => {
    if (!supabase) return
    const userId = session?.user?.id
    if (!userId) {
      setProfile(null)
      setLoading(false)
      return
    }
    setLoading(true)
    supabase
      .from('profiles')
      .select('id, full_name, role, staff_id, school_id')
      .eq('id', userId)
      // maybeSingle, not single: a PLATFORM admin has no profile at all (they
      // belong to no school), and .single() treats that as an error — which
      // would leave them stuck on a loading screen they can never get past.
      .maybeSingle()
      .then(({ data }) => {
        const p = (data as Profile) ?? null
        setProfile(p)
        // Cached so work queued while OFFLINE can still be stamped with the
        // school it belongs to — there is no server to ask at that moment.
        cacheSchoolId(p?.school_id ?? null)
        setLoading(false)
      })
  }, [session])

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

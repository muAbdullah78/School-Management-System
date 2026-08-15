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

  return (
    <AuthContext.Provider value={{ session, profile, loading, signIn, signOut }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within <AuthProvider>')
  return ctx
}

import { useState, type ReactNode } from 'react'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { getSchoolSettings } from '@/lib/db'
import { SetupWizard } from '@/pages/SetupWizard'

/**
 * Sends a brand-new school through first-run setup before it can reach the app.
 *
 * "No current academic session" is the honest signal for an unconfigured
 * school: nothing in the product works without one, so an owner who skipped
 * setup would otherwise wander a shell where every screen is empty and conclude
 * the app is broken.
 *
 * Only owner and principal can actually create a session, so anyone else
 * arriving early is told who to ask rather than shown a form that would fail.
 */
export function SetupGate({ children }: { children: ReactNode }) {
  const { profile } = useAuth()
  const [justFinished, setJustFinished] = useState(false)
  const settings = useQuery({ queryKey: ['schoolSettings'], queryFn: getSchoolSettings })

  if (settings.isLoading) return <div className="p-8 text-slate-500">Loading…</div>

  // Fail open on error — a settings hiccup should not trap an established
  // school in a setup wizard that would create a duplicate session.
  if (settings.isError) return <>{children}</>

  const configured = Boolean(settings.data?.current_session_id) || justFinished
  if (configured) return <>{children}</>

  if (profile?.role === 'owner' || profile?.role === 'principal') {
    return <SetupWizard onDone={() => setJustFinished(true)} />
  }

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-sm rounded-lg bg-white p-6 text-center shadow">
        <h1 className="text-lg font-semibold text-slate-800">Almost ready</h1>
        <p className="mt-2 text-sm text-slate-600">
          Your school is still being set up. Ask the owner or principal to finish setup, then sign in again.
        </p>
      </div>
    </div>
  )
}

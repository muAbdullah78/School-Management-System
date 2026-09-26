import { useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { useLicence } from '@/hooks/useLicence'
import { limitBanner } from '@/lib/licence'
import { pkToday } from '@/lib/db'
import { buttonClass } from '@/components/ui'

/**
 * "Your roll is full", on the dashboard only.
 *
 * It used to be a strip pinned above EVERY screen, outside the part that
 * scrolls, so on a phone it took a slice of every page for good, and with the
 * keyboard open on a form it could leave room for barely a field. The message
 * matters once a day, where the school starts its day, and the refusal itself
 * explains the rest at the moment it happens. So it lives in the dashboard's
 * own flow, scrolls away with it, and can be put away until tomorrow.
 *
 * Who is told what is still lib/licence.ts's limitBanner: the owner and
 * principal get the way to fix it, the office gets who to ask.
 */
export function RollLimitNotice() {
  const { profile } = useAuth()
  const { data } = useLicence()
  const key = `rollNotice:${profile?.school_id ?? ''}:${pkToday()}`
  const [hidden, setHidden] = useState(() => {
    try { return localStorage.getItem(key) === '1' } catch { return false }
  })
  if (!data || !data.ok || hidden) return null
  const limit = limitBanner(data, profile?.role)
  if (!limit) return null
  const canFix = profile?.role === 'owner' || profile?.role === 'principal'

  function hide() {
    setHidden(true)
    try { localStorage.setItem(key, '1') } catch { /* private window: hidden for this visit */ }
  }

  return (
    <div role="status"
      className={`mb-5 flex flex-col gap-2 rounded-xl border px-4 py-3 text-sm sm:flex-row sm:items-start sm:justify-between ${
        limit.atLimit ? 'border-due-200 bg-due-50 text-due-900' : 'border-slate-200 bg-slate-50 text-slate-700'}`}>
      <p className="min-w-0">{limit.text}</p>
      <div className="flex shrink-0 items-center gap-3">
        {canFix && (
          <Link to="/settings?tab=subscription" className={buttonClass({ size: 'sm' })}>Ask for room</Link>
        )}
        <button type="button" onClick={hide} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Hide until tomorrow</button>
      </div>
    </div>
  )
}

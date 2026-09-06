import type { ReactNode } from 'react'
import { useLicence } from '@/hooks/useLicence'
import { SchoolClosed } from '@/pages/SchoolClosed'

/**
 * The licence gate for the parent portal.
 *
 * Separate from LicenceGate rather than shared, because the two differ on every
 * decision they make. LicenceGate redirects a user with no profile to the
 * operator console and picks between two staff screens by role. A parent always
 * has a profile, is never an operator, and gets one screen.
 *
 * FAILS OPEN, like its sibling and for the same reason. If the licence call
 * itself errors, the portal loads. Shutting a paid-up school's parents out
 * because a status query timed out would be a worse failure than briefly
 * letting an unpaid school's parents in, and the database refuses them anyway
 * since 0106: this is the layer that explains, not the layer that enforces.
 */
export function PortalLicenceGate({ children }: { children: ReactNode }) {
  const { data, isLoading, isError } = useLicence()

  if (isLoading) return <div className="p-8 text-slate-500">Loading…</div>
  if (isError || !data) return <>{children}</>
  if (!data.ok) return <>{children}</>
  if (data.locked) return <SchoolClosed licence={data} audience="parent" />
  return <>{children}</>
}

import { Navigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { isParent } from '@/auth/roles'

/**
 * Sends parent accounts to the portal instead of the staff app.
 *
 * This is routing, not security. The database closes every table to a parent
 * account and serves the portal through scoped SECURITY DEFINER functions, so
 * a parent who bypassed this would land on a staff screen showing nothing at
 * all. Deleting this component would be a usability bug, not a breach, which
 * is exactly the property we want.
 */
export function PortalRoute({ children }: { children: JSX.Element }) {
  const { profile } = useAuth()
  if (isParent(profile?.role)) return <Navigate to="/portal" replace />
  return children
}

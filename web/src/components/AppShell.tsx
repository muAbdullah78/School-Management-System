import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS } from '@/auth/roles'
import { canAccess, visibleNav } from '@/navigation'
import { appTitle } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'
import { OfflineIndicator } from '@/components/OfflineIndicator'

export function AppShell() {
  const { profile, signOut } = useAuth()
  const schoolName = useSchoolName()
  const location = useLocation()
  const nav = visibleNav(profile?.role)
  const permitted = canAccess(location.pathname, profile?.role)

  return (
    <div className="flex h-full">
      <aside className="flex w-60 shrink-0 flex-col bg-brand-900 text-brand-50">
        <div className="border-b border-white/10 px-4 py-4">
          <div className="text-sm font-semibold leading-tight">{appTitle(schoolName)}</div>
          <div className="mt-0.5 text-xs text-brand-100/70">School Management System</div>
        </div>
        <nav className="flex-1 space-y-0.5 overflow-y-auto p-2">
          {nav.map((item) => (
            <NavLink
              key={item.path}
              to={item.path}
              end={item.path === '/'}
              className={({ isActive }) =>
                `block rounded px-3 py-2 text-sm ${
                  isActive ? 'bg-white/15 font-medium' : 'text-brand-100/80 hover:bg-white/10'
                }`
              }
            >
              {item.label}
            </NavLink>
          ))}
        </nav>
        <div className="border-t border-white/10 p-3 text-xs">
          <div className="font-medium">{profile?.full_name ?? 'User'}</div>
          <div className="text-brand-100/70">{profile ? ROLE_LABELS[profile.role] : ''}</div>
          <button
            onClick={() => void signOut()}
            className="mt-2 w-full rounded bg-white/10 px-3 py-1.5 text-left hover:bg-white/20"
          >
            Sign out
          </button>
        </div>
      </aside>

      <main className="flex-1 overflow-y-auto">
        <OfflineIndicator />
        <div className="mx-auto max-w-6xl p-6">
          {permitted ? (
            <Outlet />
          ) : (
            <div>
              <h1 className="text-lg font-semibold text-slate-800">Not permitted</h1>
              <p className="mt-2 text-sm text-slate-600">
                Your role does not have access to this section. Contact the school owner or principal.
              </p>
            </div>
          )}
        </div>
      </main>
    </div>
  )
}

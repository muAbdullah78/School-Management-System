import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS } from '@/auth/roles'
import { canAccess, visibleNav } from '@/navigation'
import { appTitle } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'
import { OfflineIndicator } from '@/components/OfflineIndicator'
import { LicenceBanner } from '@/components/LicenceBanner'
import { NAV_ICONS, IconLogout, IconAlert } from '@/components/icons'
import { EmptyState } from '@/components/ui'

export function AppShell() {
  const { profile, signOut } = useAuth()
  const schoolName = useSchoolName()
  const location = useLocation()
  const nav = visibleNav(profile?.role)
  const permitted = canAccess(location.pathname, profile?.role)
  const current = nav.find((n) => n.path === location.pathname)

  const initials = (profile?.full_name ?? 'U')
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('')

  return (
    <div className="flex h-full bg-slate-50">
      <aside className="flex w-64 shrink-0 flex-col bg-gradient-to-b from-brand-900 via-brand-900 to-brand-950 text-brand-50">
        {/* School identity */}
        <div className="flex items-center gap-3 border-b border-white/10 px-4 py-4">
          <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-white/10 text-sm font-bold ring-1 ring-white/15">
            {(schoolName ?? 'S').slice(0, 1).toUpperCase()}
          </span>
          <div className="min-w-0">
            <div className="truncate text-sm font-semibold leading-tight">{appTitle(schoolName)}</div>
            <div className="mt-0.5 text-[11px] uppercase tracking-wide text-brand-200/70">
              School Manager
            </div>
          </div>
        </div>

        <nav className="flex-1 space-y-0.5 overflow-y-auto p-2">
          {nav.map((item) => {
            const Icon = NAV_ICONS[item.path]
            return (
              <NavLink
                key={item.path}
                to={item.path}
                end={item.path === '/'}
                className={({ isActive }) =>
                  `group flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition ${
                    isActive
                      ? 'bg-white/15 font-medium text-white shadow-sm'
                      : 'text-brand-100/75 hover:bg-white/10 hover:text-white'
                  }`
                }
              >
                {({ isActive }) => (
                  <>
                    <span
                      className={`flex h-7 w-7 shrink-0 items-center justify-center rounded-lg transition ${
                        isActive
                          ? 'bg-white/20 text-white'
                          : 'bg-white/5 text-brand-200/80 group-hover:bg-white/10 group-hover:text-white'
                      }`}
                    >
                      {Icon ? <Icon /> : null}
                    </span>
                    <span className="truncate">{item.label}</span>
                  </>
                )}
              </NavLink>
            )
          })}
        </nav>

        {/* Who am I */}
        <div className="border-t border-white/10 p-3">
          <div className="flex items-center gap-2.5 rounded-lg bg-white/5 px-2.5 py-2">
            <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-white/15 text-xs font-semibold">
              {initials}
            </span>
            <div className="min-w-0 flex-1">
              <div className="truncate text-xs font-medium text-white">
                {profile?.full_name ?? 'User'}
              </div>
              <div className="truncate text-[11px] text-brand-200/70">
                {profile ? ROLE_LABELS[profile.role] : ''}
              </div>
            </div>
          </div>
          <button
            onClick={() => void signOut()}
            className="mt-2 flex w-full items-center justify-center gap-1.5 rounded-lg bg-white/10 px-3 py-1.5 text-xs font-medium text-brand-50 transition hover:bg-white/20"
          >
            <IconLogout />
            Sign out
          </button>
        </div>
      </aside>

      <main className="flex flex-1 flex-col overflow-hidden">
        <LicenceBanner />
        <OfflineIndicator />

        {/* Breadcrumb bar — tells you where you are without costing a heading */}
        {current ? (
          <div className="border-b border-slate-200 bg-white/80 px-6 py-2.5 backdrop-blur">
            <div className="mx-auto flex max-w-7xl items-center gap-2 text-xs text-slate-500">
              <span className="font-medium text-slate-700">{current.label}</span>
              <span className="text-slate-300">·</span>
              <span className="truncate">{current.blurb}</span>
            </div>
          </div>
        ) : null}

        <div className="flex-1 overflow-y-auto">
          <div className="mx-auto max-w-7xl p-6">
            {permitted ? (
              <Outlet />
            ) : (
              <EmptyState
                icon={<IconAlert />}
                title="Not permitted"
                message="Your role does not have access to this section. Contact the school owner or principal."
              />
            )}
          </div>
        </div>
      </main>
    </div>
  )
}

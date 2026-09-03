import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS } from '@/auth/roles'
import { canAccess, visibleNav } from '@/navigation'
import { PRODUCT_NAME, appTitle, guideUrl } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'
import { OfflineIndicator } from '@/components/OfflineIndicator'
import { LicenceBanner } from '@/components/LicenceBanner'
import { OperatorBanner } from './OperatorBanner'
import { AnnouncementBanner } from './AnnouncementBanner'
import { NAV_ICONS, IconBook, IconLogout, IconAlert } from '@/components/icons'
import { EmptyState } from '@/components/ui'
import { GlobalSearch } from '@/components/GlobalSearch'
import { ModuleSearch } from '@/components/ModuleSearch'
import { getCurrentSession } from '@/lib/db'
import { todayISO } from '@/lib/format'
import { ADMIN_ROLES } from '@/auth/roles'

export function AppShell() {
  const { profile, signOut } = useAuth()
  const schoolName = useSchoolName()
  const location = useLocation()
  const nav = visibleNav(profile?.role)
  // The module filter works over the nav THIS ROLE can already see, so it can
  // never surface a module the user has no access to.
  const [shownNav, setShownNav] = useState(nav)
  useEffect(() => setShownNav(visibleNav(profile?.role)), [profile?.role])
  const permitted = canAccess(location.pathname, profile?.role)
  const current = nav.find((n) => n.path === location.pathname)

  // The running academic session, shown in the top bar on every screen.
  //
  // WHY IT IS WORTH A QUERY ON EVERY SCREEN. There is no session picker
  // anywhere in this app: every screen calls getCurrentSession() and works on
  // whichever row has is_current. That is a good design and it has one failure
  // it cannot show — a school rolls over in April, nobody moves is_current, and
  // from then on attendance, marks and challans all go into LAST YEAR while
  // every screen looks completely normal. Nothing anywhere says which year you
  // are in.
  //
  // Staff only. A parent has no session to be in the wrong one of, and the
  // portal header is already tight on a 390px phone.
  const isStaff = !!profile && (ADMIN_ROLES as string[]).concat(
    ['class_teacher', 'subject_teacher'],
  ).includes(profile.role)
  const session = useQuery({
    queryKey: ['currentSession'],
    queryFn: getCurrentSession,
    enabled: isStaff,
    staleTime: 5 * 60 * 1000,
  })
  const sess = session.data
  // Ended, not "ending". A session whose last day has passed is the one a school
  // has usually already rolled out of, and the one where a mark entered today is
  // certainly in the wrong year.
  const sessionEnded = !!sess?.ends_on && sess.ends_on < todayISO()

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
            {/* The vendor's name, under the school's own. The line above is
                the school; this line is who made it. */}
            <div className="mt-0.5 text-[11px] uppercase tracking-wide text-brand-200/70">
              {PRODUCT_NAME}
            </div>
          </div>
        </div>

        <ModuleSearch items={nav} onFilter={setShownNav} />

        <nav className="flex-1 space-y-0.5 overflow-y-auto p-2">
          {shownNav.length === 0 && (
            <p className="px-3 py-4 text-xs text-brand-200/60">No module matches that.</p>
          )}
          {shownNav.map((item) => {
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
          {/* A staff member could not change their own password anywhere in the
              software. The only remedy was to ask the vendor to set one by hand
              and send it over WhatsApp. */}
          {/* The handbook, on its own row rather than as a third button beside
              Password and Sign out: at this width three of them are cramped,
              and this is the one a new clerk needs in their first week. New
              tab, because losing half-entered attendance to a Help click is
              exactly the kind of thing that stops people clicking Help. */}
          <a
            href={guideUrl}
            target="_blank"
            rel="noopener"
            className="mt-2 flex items-center justify-center gap-1.5 rounded-lg bg-white/10 px-2 py-1.5 text-xs font-medium text-brand-50 transition hover:bg-white/20"
          >
            <IconBook />
            How to use this
          </a>
          <div className="mt-2 flex gap-2">
            <NavLink
              to="/password"
              className="flex flex-1 items-center justify-center rounded-lg bg-white/10 px-2 py-1.5 text-xs font-medium text-brand-50 transition hover:bg-white/20"
            >
              Password
            </NavLink>
            <button
              onClick={() => void signOut()}
              className="flex flex-1 items-center justify-center gap-1.5 rounded-lg bg-white/10 px-2 py-1.5 text-xs font-medium text-brand-50 transition hover:bg-white/20"
            >
              <IconLogout />
              Sign out
            </button>
          </div>
        </div>
      </aside>

      <main className="flex flex-1 flex-col overflow-hidden">
        {/* ABOVE the licence banner, deliberately. "You are in somebody
            else's data" outranks "your subscription expires on Friday": one
            is about what you are looking at right now. */}
        <OperatorBanner />
        <LicenceBanner />
        {/* BELOW both. "Somebody from the vendor is in your data" and "your
            licence expires Friday" are both about this school; a maintenance
            notice is about everybody, and it is the one that can wait. */}
        <AnnouncementBanner />
        <OfflineIndicator />

        {/* Top bar: where you are, and the one search box.
            Always rendered — the breadcrumb half is conditional, the search is
            not, because "reachable from anywhere" is the whole point of it. */}
        <div className="border-b border-slate-200 bg-white/80 px-6 py-2.5 backdrop-blur print:hidden">
          <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3">
            {/* The running session, first thing on the bar. Their product keeps
                it in the footer; here it sits next to where-you-are, because
                "which year am I entering this into" is the same kind of fact as
                "which screen am I on". */}
            {isStaff && (
              sess ? (
                <span
                  className={`shrink-0 rounded px-2 py-0.5 text-xs font-medium ${
                    sessionEnded
                      ? 'bg-amber-100 text-amber-900 ring-1 ring-amber-300'
                      : 'bg-slate-100 text-slate-600'
                  }`}
                  title={sessionEnded
                    ? `Session ${sess.name} ended on ${sess.ends_on}. Everything entered now is recorded against it. Settings → Sessions to move on.`
                    : `Everything you enter is recorded against ${sess.name}`}
                >
                  {sess.name}
                  {sessionEnded ? ' · ended' : ''}
                </span>
              ) : session.isFetched ? (
                <span className="shrink-0 rounded bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900 ring-1 ring-amber-300"
                  title="No academic session is marked as current, so most screens have nothing to work on. Settings → Sessions.">
                  No session set
                </span>
              ) : null
            )}
            <div className="flex min-w-0 items-center gap-2 text-xs text-slate-500">
              {current ? (
                <>
                  <span className="font-medium text-slate-700">{current.label}</span>
                  <span className="text-slate-300">·</span>
                  <span className="truncate">{current.blurb}</span>
                </>
              ) : null}
            </div>
            <div className="ml-auto w-full sm:w-auto sm:min-w-[22rem]">
              <GlobalSearch />
            </div>
          </div>
        </div>

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

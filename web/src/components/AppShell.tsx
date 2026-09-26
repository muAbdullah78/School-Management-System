import { useCallback, useEffect, useRef, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { useAuth } from '@/auth/AuthProvider'
import { ROLE_LABELS } from '@/auth/roles'
import { NAV_GROUPS, canAccess, navLabel, visibleNav } from '@/navigation'
import { PRODUCT_NAME, guideUrl } from '@/lib/config'
import { useSchoolName } from '@/hooks/useSchoolName'
import { OfflineIndicator } from '@/components/OfflineIndicator'
import { LicenceBanner } from '@/components/LicenceBanner'
import { OperatorBanner } from './OperatorBanner'
import { AnnouncementBanner } from './AnnouncementBanner'
import { NAV_ICONS, IconBook, IconLogout, IconAlert, IconMenu, IconX, IconLock, IconSidebarFold } from '@/components/icons'
import { EmptyState } from '@/components/ui'
import { GlobalSearch } from '@/components/GlobalSearch'
import { ModuleSearch } from '@/components/ModuleSearch'
import { getCurrentSession } from '@/lib/db'
import { todayISO } from '@/lib/format'
import { ADMIN_ROLES } from '@/auth/roles'
import { useSchoolLogo } from '@/hooks/useSchoolLogo'
import { useSupportVisit } from '@/hooks/useSupportVisit'
import { useIsDesktop } from '@/hooks/useIsDesktop'
import { FIT_MAX_LINES, fitSchoolName } from '@/lib/schoolLabel'

/* Tailwind reads this file as TEXT, so a class it is going to emit has to
   appear here spelled out in full. `line-clamp-${n}` would be found by nobody,
   generate nothing, and clamp at no lines at all -- which looks like it works
   until a name is long enough to need it. Written out, indexed by the ladder's
   own maximum, so the clamp cannot drift away from the ladder. */
/* THE NARROWEST THE NAME'S BOX EVER GETS, in pixels, and it is worked out
   rather than guessed: the ladder in fitSchoolName only keeps its promise if
   the width it is given is one the name really has.

   It is the DRAWER that is tightest, not the desktop sidebar, because the
   drawer carries a close button the sidebar does not:

     drawer at its narrowest   min(288 from w-72, 320 - 48 from max-w)   272
     less px-4 on both sides                                       -32   240
     less the 40px logo and the 12px gap beside it                 -52   188
     less the 40px close button, its 12px gap, its -6px pull       -46   142

   The desktop sidebar is 256 less 32 of padding less the same logo and gap,
   with no close button and so no gap before one: 172. Sizing everything for
   142 gives a desktop 30px it does not spend, which is invisible, and is the
   only number under which the fit holds at both. 320px is the floor because
   that is the narrowest phone still sold in this market. */
const NAME_BOX_PX = 142

const RAIL_KEY = 'tsm.sidebar.folded'

const CLAMP: Record<number, string> = {
  1: 'line-clamp-1',
  2: 'line-clamp-2',
  3: 'line-clamp-3',
  4: 'line-clamp-4',
}

export function AppShell() {
  const { profile, signOut } = useAuth()
  const schoolName = useSchoolName()
  const location = useLocation()
  // WHO THIS SHELL IS BEING DRAWN FOR.
  //
  // Normally the signed-in user's own role. During a support visit there is no
  // profile at all -- a platform admin belongs to no school -- and with an
  // undefined role visibleNav returns almost nothing and canAccess refuses
  // every path, so the operator would arrive at an empty shell reading "Your
  // role does not have access to this section" on every screen.
  //
  // `readonly` is the honest answer rather than a convenience. It is the
  // observer role 0059 created for exactly this shape: may look at everything,
  // may change nothing. And it is not the enforcement, which matters more: the
  // database refuses every write from an operator session on its own, so this
  // only decides what is worth drawing.
  const visit = useSupportVisit().visit
  const role = profile?.role ?? (visit ? ('readonly' as const) : undefined)
  const nav = visibleNav(role)
  // The module filter works over the nav THIS ROLE can already see, so it can
  // never surface a module the user has no access to.
  const [shownNav, setShownNav] = useState(nav)
  useEffect(() => setShownNav(visibleNav(role)), [role])
  const permitted = canAccess(location.pathname, role)
  const current = nav.find((n) => n.path === location.pathname)

  // The running academic session, shown in the top bar on every screen.
  //
  // WHY IT IS WORTH A QUERY ON EVERY SCREEN. There is no session picker
  // anywhere in this app: every screen calls getCurrentSession() and works on
  // whichever row has is_current. That is a good design and it has one failure
  // it cannot show. A school rolls over in April, nobody moves is_current, and
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

  // Returns null when there is no logo or the signed URL cannot be made, so the
  // letter tile below is the fallback rather than a broken image.
  const logo = useSchoolLogo()

  /* ------------------------------------------------------ the mobile drawer --
   *
   * WHAT WAS WRONG. The sidebar was `w-64 shrink-0` with no breakpoint on it at
   * all, so on a 390px phone it took 256 of those pixels and left 134 for the
   * attendance register, the cash drawer and every table in the product. That
   * is not a cramped layout, it is an unusable one, and every screen in the
   * app inherited it.
   *
   * ONE ELEMENT, NOT TWO. The obvious fix is a second copy of the sidebar for
   * small screens, and it is the wrong one: two copies means two module search
   * boxes with two independent filter states, two nav lists to keep in step,
   * and a second place for every future change to be forgotten. So there is
   * exactly one <aside> in this file. Below `lg` it is `fixed` and slid out of
   * frame by a transform; at `lg` it is `static` and back in the flex row where
   * it always was. The desktop layout is byte for byte the one that shipped.
   *
   * TRANSFORM, NOT WIDTH. Animating a width or a margin makes the browser lay
   * the whole page out again on every frame of the slide, with every table in
   * the content area reflowing behind it. A transform is composited and touches
   * nothing else, so the drawer stays at 60fps on the cheap Android phones this
   * is actually used on.
   *
   * VISIBILITY, NOT JUST A TRANSFORM. An element pushed off screen by a
   * transform is still in the accessibility tree and still in the tab order,
   * so a keyboard user tabbing through the page would fall into an invisible
   * sidebar and a screen reader would read out the whole menu twice. So the
   * closed drawer is `invisible`, and because `visibility` is animatable as a
   * step that flips at the END of a transition, it stays visible for the whole
   * slide out and disappears exactly when it lands. No JavaScript timer.
   */
  const isDesktop = useIsDesktop()
  const [navOpen, setNavOpen] = useState(false)
  // The single truth. `navOpen` is only ever asked about below `lg`, so nothing
  // downstream has to remember that an open drawer means nothing on a desktop.
  const drawerOpen = navOpen && !isDesktop

  /* The folded rail: a desktop choice, remembered on this computer. Storage
     can throw (a private window, blocked site data), and then the sidebar
     simply opens unfolded. */
  const [collapsed, setCollapsed] = useState<boolean>(() => {
    try { return window.localStorage.getItem(RAIL_KEY) === '1' } catch { return false }
  })
  useEffect(() => {
    try { window.localStorage.setItem(RAIL_KEY, collapsed ? '1' : '0') } catch { /* not remembered, that is all */ }
  }, [collapsed])
  const rail = collapsed && isDesktop
  const closeNav = useCallback(() => setNavOpen(false), [])
  const menuButtonRef = useRef<HTMLButtonElement>(null)
  const closeButtonRef = useRef<HTMLButtonElement>(null)
  const drawerRef = useRef<HTMLElement>(null)

  // Navigating closes it. Without this, tapping a module slides the new screen
  // in behind a drawer that is still covering it.
  useEffect(() => { setNavOpen(false) }, [location.pathname])

  // Turning a phone to landscape, or dragging a desktop window wider, crosses
  // the breakpoint with the drawer still flagged open. The CSS puts the sidebar
  // back where it belongs on its own, but the flag would survive to ambush the
  // user the next time the window got narrow again.
  useEffect(() => { if (isDesktop) setNavOpen(false) }, [isDesktop])

  /* While the drawer is open it is a modal dialog, and a modal dialog owes the
     user three things that a sliding div does not give them for free. */
  useEffect(() => {
    if (!drawerOpen) return
    const panel = drawerRef.current
    if (!panel) return
    const opener = menuButtonRef.current

    // 1. Focus goes in. On the close button rather than the first link, so the
    //    way out is the first thing under the user's thumb or Tab key.
    closeButtonRef.current?.focus()

    // Everything in the drawer is on screen whenever this runs -- the trap is
    // only armed below `lg`, where nothing inside it is hidden -- so this asks
    // the DOM for the tab stops rather than measuring them. A filter on
    // offsetParent would be the usual way to drop hidden ones and it is a trap
    // of its own: jsdom does no layout, so offsetParent is null for every
    // element in every test and the filter would quietly remove them all.
    const FOCUSABLE =
      'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),'
      + 'textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
    const stops = () =>
      Array.from(panel.querySelectorAll<HTMLElement>(FOCUSABLE))
        .filter((el) => !el.hasAttribute('hidden'))

    // An arrow bound to a const rather than a hoisted declaration, so the
    // null check on `panel` above still narrows inside it.
    const onKeyDown = (e: KeyboardEvent) => {
      // 2. Escape closes it. The single most reached for key on anything that
      //    covers the screen, and the page behind is still live without it.
      if (e.key === 'Escape') { e.preventDefault(); setNavOpen(false); return }
      if (e.key !== 'Tab') return
      // 3. Tab stays inside. Without this, Tab walks straight out of the open
      //    drawer and into the page underneath it, which the user cannot see
      //    and which their next keystroke would then act on.
      const els = stops()
      if (els.length === 0) return
      const first = els[0]
      const last = els[els.length - 1]
      const active = document.activeElement
      const outside = !active || !panel.contains(active)
      if (e.shiftKey && (outside || active === first)) { e.preventDefault(); last.focus() }
      else if (!e.shiftKey && (outside || active === last)) { e.preventDefault(); first.focus() }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      // And focus comes back out, to the button that opened it. Only when it is
      // still inside the drawer or nowhere in particular: if something else on
      // the page has deliberately taken focus in the meantime, taking it away
      // again would be the bug.
      const active = document.activeElement
      if (!active || active === document.body || panel.contains(active)) opener?.focus()
    }
  }, [drawerOpen])

  /* THE SCHOOL'S OWN NAME, WHOLE.
   *
   * Two things were wrong with the line this replaces, and the truncation was
   * the smaller one.
   *
   * It rendered appTitle(schoolName), which is "{name} Manager" -- directly
   * above a second line reading THE SCHOOL MANAGER. So the word said itself
   * twice, and the first copy was glued onto the customer's name where it read
   * as part of it: "Government Girls High School Manager". appTitle is right
   * for the browser tab and for the check-in screen, where nothing else says
   * what the software is. It is wrong in the one place that already does, and
   * dropping it gives eight characters back to the name.
   *
   * Then `truncate` on a fixed 172px box cut whatever was left at about twenty
   * characters. A school's own name is the one string in this product that must
   * never look broken, and in this market it is routinely fifty characters:
   * "Government Girls Higher Secondary School Chaklala". fitSchoolName steps
   * the size down and lets it wrap instead, so an ordinary long name arrives
   * whole. See lib/schoolLabel.ts for the ladder and what is at the bottom of
   * it. */
  const fullName = (schoolName ?? '').trim()
  const fitted = fitSchoolName(fullName, PRODUCT_NAME, NAME_BOX_PX)

  const initials = (profile?.full_name ?? 'U')
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('')

  return (
    <div className="flex h-full bg-slate-50">
      {/* THE BACKDROP.
          Mounted at all times below `lg` rather than conditionally rendered, so
          the fade plays on the way OUT as well as in: a backdrop that vanishes
          the instant you tap it makes the drawer look like it jumped rather
          than slid. It cannot swallow a click while the drawer is shut because
          it is pointer-events-none until it is needed, and it does not exist at
          all from `lg` upwards. aria-hidden because the real way out for a
          keyboard is Escape and the close button, both of which are handled
          above; a focusable backdrop would just be one more Tab stop. */}
      <div
        aria-hidden="true"
        onClick={closeNav}
        className={`fixed inset-0 z-40 bg-slate-900/60 transition-opacity duration-300 motion-reduce:transition-none lg:hidden print:hidden ${
          drawerOpen ? 'opacity-100' : 'pointer-events-none opacity-0'
        }`}
      />

      <aside
        ref={drawerRef}
        id="app-sidebar"
        /* A dialog only while it is behaving like one. At `lg` the sidebar is
           simply part of the page, and telling a screen reader that the page
           furniture is a modal dialog would be worse than saying nothing. */
        {...(isDesktop
          ? {}
          : { role: 'dialog', 'aria-modal': true, 'aria-label': 'Menu' })}
        className={
          'fixed inset-y-0 left-0 z-50 flex w-72 max-w-[calc(100vw-3rem)] flex-col overflow-hidden '
          + 'bg-gradient-to-b from-brand-900 via-brand-900 to-violet-950 text-brand-50 '
          + 'shadow-2xl transition-[transform,visibility,width] duration-300 ease-out '
          + 'motion-reduce:transition-none print:hidden '
          + 'lg:static lg:z-auto lg:max-w-none lg:shrink-0 '
          + (rail ? 'lg:w-[4.75rem] ' : 'lg:w-64 ')
          + 'lg:visible lg:translate-x-0 lg:shadow-none '
          + (drawerOpen ? 'visible translate-x-0' : 'invisible -translate-x-full')
        }
      >
        {/* A glow in the corner, drawn and not a picture: it costs no request
            and tints with the brand. */}
        <span className="pointer-events-none absolute -left-16 -top-24 h-56 w-56 rounded-full bg-fuchsia-500/20 blur-3xl" />
        <span className="pointer-events-none absolute -bottom-24 -right-20 h-56 w-56 rounded-full bg-brand-400/10 blur-3xl" />

        {/* School identity.
            shrink-0 here and on the footer below, so that on a short window
            the module list is the one thing that gives way. */}
        <div className={`relative flex shrink-0 items-center gap-3 border-b border-white/10 py-4 ${rail ? 'justify-center px-2' : 'px-4'}`}>
          {/* The school's OWN logo, if they have uploaded one, else its first
              letter: most schools never upload one. */}
          {logo ? (
            <img
              src={logo}
              alt=""
              className="h-10 w-10 shrink-0 rounded-xl bg-white object-contain p-0.5 shadow-lg shadow-brand-950/40 ring-1 ring-white/20"
            />
          ) : (
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-gradient-to-br from-fuchsia-400 to-brand-500 text-base font-bold text-white shadow-lg shadow-brand-950/40 ring-1 ring-white/20">
              {(schoolName ?? 'S').slice(0, 1).toUpperCase()}
            </span>
          )}
          <div className={`min-w-0 flex-1 ${rail ? 'hidden' : ''}`}>
            {/* WRAPS, NEVER TRUNCATES. `break-words` is the guard against a
                single unbroken token longer than the box; the clamp is the
                ladder's own maximum; `title` carries the whole name when the
                clamp is reached. */}
            <div
              className={`break-words font-semibold leading-tight text-white ${CLAMP[FIT_MAX_LINES] ?? 'line-clamp-3'}`}
              style={{ fontSize: `${fitted.size}px`, ...fitted.style }}
              dir={fitted.rtl ? 'rtl' : undefined}
              lang={fitted.rtl ? 'ur' : undefined}
              title={fitted.clipped ? fullName : undefined}
            >
              {fitted.text}
            </div>
            {/* The vendor's name, under the school's own. */}
            <div className="mt-0.5 text-[10px] font-semibold uppercase tracking-[0.14em] text-brand-200/70">
              {PRODUCT_NAME}
            </div>
          </div>

          {/* The way out, and the first thing focus lands on when the drawer
              opens. 40px square because a thumb is not a mouse pointer. */}
          <button
            ref={closeButtonRef}
            type="button"
            onClick={closeNav}
            aria-label="Close menu"
            className="-mr-1.5 flex h-10 w-10 shrink-0 items-center justify-center rounded-xl text-brand-100/80 transition hover:bg-white/10 hover:text-white focus:outline-none focus-visible:ring-2 focus-visible:ring-white/70 lg:hidden"
          >
            <IconX className="h-5 w-5" />
          </button>
        </div>

        {/* A search over five rows is a box to look past: shown when the list
            is long enough to need one, and never in the folded rail. */}
        {nav.length > 7 && !rail && <ModuleSearch items={nav} onFilter={setShownNav} />}

        {/* overscroll-contain so flicking to the bottom of the module list on a
            phone stops there instead of handing the rest of the gesture to the
            page underneath the drawer. */}
        <nav aria-label="Modules" className={`relative flex-1 overflow-y-auto overscroll-contain pb-3 pt-1 ${rail ? 'px-2' : 'px-3'}`}
          style={{ scrollbarWidth: 'thin' }}>
          {shownNav.length === 0 && (
            <p className="px-3 py-4 text-xs text-brand-200/60">No module matches that.</p>
          )}
          {NAV_GROUPS.map((g, gi) => {
            const items = shownNav.filter((n) => n.group === g.key)
            if (items.length === 0) return null
            // Named sections earn their room on a long list. A teacher's five
            // rows are split by a hairline instead of five headings over them.
            const named = nav.length > 7 && !rail
            const first = !NAV_GROUPS.slice(0, gi).some((x) => shownNav.some((n) => n.group === x.key))
            return (
              <div key={g.key} role="group" aria-label={g.label}>
                {named ? (
                  <div className="px-3 pb-1 pt-3 text-[10px] font-semibold uppercase tracking-[0.14em] text-brand-200/50">
                    {g.label}
                  </div>
                ) : !first ? (
                  <div className={`my-2 h-px bg-white/10 ${rail ? 'mx-2' : 'mx-3'}`} />
                ) : <div className="h-2" />}
                <ul className="space-y-0.5">
                  {items.map((item) => {
                    const Icon = NAV_ICONS[item.path]
                    const label = navLabel(item, role)
                    return (
                      <li key={item.path}>
                        <NavLink
                          to={item.path}
                          end={item.path === '/'}
                          /* Tapping the module you are already on does not
                             change the path, so the route effect never fires
                             and the drawer would sit there looking stuck. */
                          onClick={closeNav}
                          title={rail ? label : undefined}
                          className={({ isActive }) =>
                            `group relative flex items-center gap-3 rounded-xl text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-white/70 ${
                              rail ? 'justify-center px-0 py-2.5' : 'px-3 py-2'} ${
                              isActive
                                ? 'bg-white text-brand-900 shadow-lg shadow-brand-950/30'
                                : 'text-brand-100/80 hover:bg-white/10 hover:text-white'
                            }`
                          }
                        >
                          {({ isActive }) => (
                            <>
                              <span className={`flex shrink-0 items-center justify-center text-[1.15rem] transition ${
                                isActive ? 'text-brand-600' : 'text-brand-300 group-hover:text-white'}`}>
                                {Icon ? <Icon /> : null}
                              </span>
                              <span className={rail ? 'sr-only' : 'truncate'}>{label}</span>
                              {isActive && !rail && (
                                <span className="ml-auto h-1.5 w-1.5 shrink-0 rounded-full bg-fuchsia-500" aria-hidden />
                              )}
                            </>
                          )}
                        </NavLink>
                      </li>
                    )
                  })}
                </ul>
              </div>
            )
          })}
        </nav>

        {/* Who am I, and the three things a person does to their own account.
            One card instead of three full-width buttons stacked the same
            weight as the modules above them. */}
        <div className={`relative shrink-0 border-t border-white/10 ${rail ? 'p-2' : 'p-3'}`}>
          <div className={`rounded-2xl bg-white/[0.07] ring-1 ring-white/10 ${rail ? 'p-1.5' : 'p-2.5'}`}>
            <div className={`flex items-center gap-2.5 ${rail ? 'justify-center' : ''}`}
              title={rail ? `${profile?.full_name ?? (visit ? 'Support visit' : 'User')}${profile ? `, ${ROLE_LABELS[profile.role]}` : ''}` : undefined}>
              <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-gradient-to-br from-fuchsia-400 to-violet-500 text-xs font-bold text-white ring-2 ring-white/20">
                {initials}
              </span>
              <div className={`min-w-0 flex-1 ${rail ? 'hidden' : ''}`}>
                <div className="truncate text-sm font-semibold text-white">
                  {profile?.full_name ?? (visit ? 'Support visit' : 'User')}
                </div>
                <div className="truncate text-[11px] text-brand-200/80">
                  {profile ? ROLE_LABELS[profile.role] : (visit ? 'Read only' : '')}
                </div>
              </div>
              {/* Folding is a desktop choice, remembered on this computer: on a
                  laptop the register and the marks sheet get 180 pixels back.
                  Not rendered at all below `lg`, where a hidden button would
                  still be the last stop of the drawer's focus trap. */}
              {isDesktop && !rail && (
                <button type="button" onClick={() => setCollapsed(true)} aria-label="Collapse the sidebar"
                  title="Collapse the sidebar"
                  className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg text-brand-200/70 transition hover:bg-white/10 hover:text-white">
                  <IconSidebarFold className="h-4 w-4" />
                </button>
              )}
            </div>
            {/* A staff member could not change their own password anywhere in
                the software before this row. The handbook opens in a new tab,
                because losing half-entered attendance to a Help click is what
                stops people clicking Help. */}
            <div className={`mt-2 grid gap-1 ${rail ? 'grid-cols-1' : 'grid-cols-3'}`}>
              <a
                href={guideUrl}
                target="_blank"
                rel="noopener"
                onClick={closeNav}
                title="How to use this: the handbook, in a new tab"
                className="flex flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 text-[11px] font-medium text-brand-100/90 transition hover:bg-white/10 hover:text-white"
              >
                <IconBook className="h-4 w-4" />
                <span className={rail ? 'sr-only' : ''}>Guide</span>
              </a>
              <NavLink
                to="/password"
                onClick={closeNav}
                title={rail ? 'Password' : undefined}
                className="flex flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 text-[11px] font-medium text-brand-100/90 transition hover:bg-white/10 hover:text-white"
              >
                <IconLock className="h-4 w-4" />
                <span className={rail ? 'sr-only' : ''}>Password</span>
              </NavLink>
              <button
                type="button"
                onClick={() => void signOut()}
                title={rail ? 'Sign out' : undefined}
                className="flex flex-col items-center gap-0.5 rounded-xl px-1 py-1.5 text-[11px] font-medium text-brand-100/90 transition hover:bg-danger-500/20 hover:text-white"
              >
                <IconLogout className="h-4 w-4" />
                <span className={rail ? 'sr-only' : ''}>Sign out</span>
              </button>
            </div>
          </div>
          {rail && (
            <button type="button" onClick={() => setCollapsed(false)} aria-label="Expand the sidebar"
              title="Expand the sidebar"
              className="mt-2 flex w-full items-center justify-center rounded-xl py-1.5 text-brand-200/70 transition hover:bg-white/10 hover:text-white">
              <IconSidebarFold className="h-4 w-4 rotate-180" />
            </button>
          )}
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
            Always rendered. The breadcrumb half is conditional, the search is
            not, because "reachable from anywhere" is the whole point of it. */}
        <div className="border-b border-slate-200 bg-white/80 px-4 py-2.5 backdrop-blur sm:px-6 print:hidden">
          <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3">
            {/* THE WAY IN, AND IT IS IN THIS BAR RATHER THAN IN A NEW ONE.
                A second sticky header above this one would be the usual answer
                and it would cost a phone another 56px of chrome plus a second
                border, on the screens with the least room to spare. This bar is
                already pinned above the scroller and already carries where you
                are, so the button belongs in it. From `lg` upwards the button
                and the mark beside it are not rendered at all and this bar is
                exactly what it was. */}
            <button
              ref={menuButtonRef}
              type="button"
              onClick={() => setNavOpen(true)}
              aria-label="Open menu"
              aria-controls="app-sidebar"
              aria-expanded={drawerOpen}
              className="-ml-2 flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-slate-600 transition hover:bg-slate-100 hover:text-slate-900 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 lg:hidden"
            >
              <IconMenu className="h-6 w-6" />
            </button>
            {/* The school's mark, and deliberately the mark ALONE. With the
                sidebar off canvas a phone would otherwise show no sign of whose
                software this is, and 32 pixels buys that back without taking
                any of the width the screen title and the session need. The name
                itself is one tap away at the top of the drawer, whole. */}
            {logo ? (
              <img
                src={logo}
                alt=""
                className="h-8 w-8 shrink-0 rounded-lg bg-white object-contain p-0.5 ring-1 ring-slate-200 lg:hidden"
              />
            ) : (
              <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-xs font-bold text-brand-700 ring-1 ring-brand-100 lg:hidden">
                {(fullName || PRODUCT_NAME).slice(0, 1).toUpperCase()}
              </span>
            )}
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
            {/* The blurb is a sentence explaining the module and there is no
                room for a sentence beside a hamburger, a logo and the session
                on a 390px phone. The label is the part that answers "where am
                I", so the label survives and the sentence waits for a screen
                that can hold it. */}
            <div className="flex min-w-0 flex-1 items-center gap-2 text-xs text-slate-500">
              {current ? (
                <>
                  <span className="truncate font-medium text-slate-700">{navLabel(current, role)}</span>
                  <span className="hidden text-slate-300 sm:inline">·</span>
                  <span className="hidden truncate sm:inline">{current.blurb}</span>
                </>
              ) : null}
            </div>
            <div className="ml-auto w-full sm:w-auto sm:min-w-[22rem]">
              <GlobalSearch />
            </div>
          </div>
        </div>

        <div className="flex-1 overflow-y-auto">
          {/* p-6 on a 390px phone spends 48 of them on nothing. */}
          <div className="mx-auto max-w-7xl p-4 sm:p-6">
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

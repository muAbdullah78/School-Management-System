import { useEffect, useState } from 'react'

/**
 * Is the window wide enough for the sidebar to live on screen permanently?
 *
 * WHY A HOOK AND NOT JUST A TAILWIND BREAKPOINT. The layout itself is done in
 * CSS and stays in CSS: the sidebar slides with `lg:` classes and never depends
 * on JavaScript to be in the right place. What CSS cannot do is change what the
 * element MEANS. Below this width the sidebar is a modal dialog laid over the
 * page: it takes focus, it traps Tab, Escape closes it, and it must announce
 * itself as a dialog. At and above it, it is a plain navigation landmark that
 * is simply always there, and a focus trap on it would be a bug rather than a
 * feature. Those are two different sets of ARIA attributes and two different
 * keyboard behaviours, so something in JavaScript has to know which one is in
 * force.
 *
 * ONE DEFINITION OF THE BREAKPOINT. The query below is 1024px because `lg:` is
 * 1024px. If one of them moves the other has to move with it, so the constant
 * is exported and the shell's test asserts the pair still agree.
 *
 * WHY IT DEFAULTS TO TRUE WHERE matchMedia IS MISSING. jsdom does not implement
 * matchMedia at all, and neither does a server render. Defaulting to the
 * desktop shape means a test that does not care about the drawer mounts the
 * classic layout with everything visible, which is both the safer failure and
 * the one that matches what the CSS does when it cannot evaluate a query.
 */
export const DESKTOP_QUERY = '(min-width: 1024px)'

function supported(): boolean {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function'
}

function read(): boolean {
  return supported() ? window.matchMedia(DESKTOP_QUERY).matches : true
}

export function useIsDesktop(): boolean {
  const [isDesktop, setIsDesktop] = useState(read)

  useEffect(() => {
    if (!supported()) return
    const mql = window.matchMedia(DESKTOP_QUERY)
    const onChange = () => setIsDesktop(mql.matches)
    // Read once on mount as well: between the first render and this effect the
    // window can already have been resized, and on a rehydrated page it can
    // have been resized while the tab was in the background.
    onChange()
    // addEventListener is the modern spelling; addListener is what Safari below
    // 14 has, and a school on an old iPad is not a hypothetical here.
    if (typeof mql.addEventListener === 'function') {
      mql.addEventListener('change', onChange)
      return () => mql.removeEventListener('change', onChange)
    }
    if (typeof mql.addListener === 'function') {
      mql.addListener(onChange)
      return () => mql.removeListener(onChange)
    }
    return
  }, [])

  return isDesktop
}

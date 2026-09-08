import { describe, expect, it } from 'vitest'
import { NAV, visibleNav, canAccess } from '@/navigation'
import { NAV_ICONS } from '@/components/icons'

/**
 * THE SIDEBAR HAS TO BE READABLE, and two of its rows were not.
 *
 * Birthdays and Enquiries were added to NAV and nobody added them to
 * NAV_ICONS. AppShell does `const Icon = NAV_ICONS[item.path]` and then
 * `{Icon ? <Icon /> : null}`, so the lookup came back undefined, the guard did
 * its job, and both rows drew the icon badge with nothing inside it. It looked
 * like a rendering bug rather than a missing entry, and it survived because
 * nothing anywhere connected the two lists.
 *
 * The same omission wearing a disguise: Accounts and Cash drawer both pointed
 * at IconWallet. Nothing was blank, so nothing looked wrong, and the reader
 * scanning for the drawer found two rows with the same picture. An icon that
 * does not tell one row from another is doing no work.
 *
 * Both are now assertions rather than habits.
 */
describe('every module in the sidebar can be recognised', () => {
  it('gives every nav row an icon', () => {
    const missing = NAV.filter((item) => !NAV_ICONS[item.path]).map((i) => i.label)
    expect(missing).toEqual([])
  })

  it('gives no two nav rows the same icon', () => {
    const byIcon = new Map<unknown, string[]>()
    for (const item of NAV) {
      const icon = NAV_ICONS[item.path]
      byIcon.set(icon, [...(byIcon.get(icon) ?? []), item.label])
    }
    const shared = [...byIcon.values()].filter((labels) => labels.length > 1)
    expect(shared).toEqual([])
  })

  it('carries an icon for the two screens that are routes but not nav rows', () => {
    // /my-class is the teacher's own landing screen and /platform is ours.
    // Neither is in NAV, both are reached by URL and by redirect, and both
    // appear in the shell's header, so both still need a glyph.
    expect(NAV_ICONS['/my-class']).toBeTruthy()
    expect(NAV_ICONS['/platform']).toBeTruthy()
  })

  it('maps no icon to a path that is not a screen', () => {
    // A stale entry is harmless on screen and is still a lie in the map: it
    // says a module exists. This catches a path renamed in NAV and left behind
    // here, which is exactly how a nav row loses its icon in the first place.
    const known = new Set([...NAV.map((n) => n.path), '/my-class', '/platform'])
    const orphans = Object.keys(NAV_ICONS).filter((p) => !known.has(p))
    expect(orphans).toEqual([])
  })
})

describe('who can see which module', () => {
  it('shows the whole map to an owner and nothing extra to a signed-out visitor', () => {
    expect(visibleNav('owner').length).toBe(NAV.length)
    // Signed out, only the rows open to everyone show: the Dashboard.
    expect(visibleNav(null).map((n) => n.path)).toEqual(['/'])
  })

  it('agrees with itself: a row a role cannot see is a row it cannot open', () => {
    const roles = [...new Set(NAV.flatMap((n) => n.roles))]
    for (const role of roles) {
      const seen = new Set(visibleNav(role).map((n) => n.path))
      for (const item of NAV) {
        expect(canAccess(item.path, role)).toBe(seen.has(item.path))
      }
    }
  })

  it('refuses a path it has never heard of', () => {
    expect(canAccess('/not-a-module', 'owner')).toBe(false)
  })
})

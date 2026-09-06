// @vitest-environment jsdom
import { describe, expect, it } from 'vitest'
import { signInMessage } from '@/pages/Login'
import {
  OFFICE_DOOR, PARENT_DOOR, OPERATOR_DOOR, SIGNUP_DOOR, RECOVERY_DOOR,
  DOOR_PATH, parentPortalLink,
} from '@/auth/doors'

/**
 * The rules the doors exist to keep, asserted where they can be.
 *
 * The thing that actually mattered about this change cannot be asserted:
 * whether a parent opening the page on a phone can tell it is for them. That is
 * judged from web/tools/doors-preview.test.tsx. What IS assertable is the set of
 * facts the old single page got wrong, and each of these is one of them.
 */
describe('the three doors', () => {
  it('never puts a price in front of a parent', () => {
    // The old page's support column carried "From Rs 2,000 a month" and, on a
    // phone where the column is hidden, the price was the one thing that
    // survived into the footer strip. So the single thing guaranteed to reach a
    // parent on a phone was the monthly cost of the software their school buys.
    expect(PARENT_DOOR.footNote).not.toMatch(/Rs|price|month/i)
    expect(PARENT_DOOR.column).toBe('portal')
    // And the operator, who needs no persuading at all, gets no strip.
    expect(OPERATOR_DOOR.footNote).toBe('')
    expect(OPERATOR_DOOR.column).toBe('none')
    // The buyer still gets it, on the two pages a buyer stands at.
    expect(OFFICE_DOOR.footNote).toMatch(/Rs 2,000/)
    expect(SIGNUP_DOOR.footNote).toMatch(/Rs 2,000/)
  })

  it('offers the trial only where a school buyer might be standing', () => {
    // THE TRAP THIS CLOSES. "Start a free 14-day trial" was the only prominent
    // alternative to the form, which makes it what a parent or teacher who
    // cannot get in presses. And it works: they get a whole new school and
    // become its owner, the vendor gets an orphan tenant in the console, and
    // the person believes they have signed in.
    expect(OFFICE_DOOR.offerTrial).toBe(true)
    expect(PARENT_DOOR.offerTrial).toBe(false)
    expect(OPERATOR_DOOR.offerTrial).toBe(false)
  })

  it('tells everybody what to do when they do not know their details', () => {
    // The old page said "Use the email address your account was set up with",
    // which is true for an owner and useless for a parent, whose address was
    // invented by the office and may never have been told to them properly.
    expect(PARENT_DOOR.ifUnknown).toMatch(/school office/i)
    expect(OFFICE_DOOR.ifUnknown).toMatch(/owner or principal/i)
    for (const d of [OFFICE_DOOR, PARENT_DOOR]) {
      expect(d.ifUnknown.length).toBeGreaterThan(20)
    }
  })

  it('is honest about a reset email that cannot arrive', () => {
    // A school invents most of the addresses it hands out (0116), so the reset
    // link posts into a mailbox nobody owns. Offering a remedy that silently
    // fails is worse than offering none, and the honest alternative only became
    // sayable once the office could look the password up.
    expect(PARENT_DOOR.resetFirst).toBe(false)
    expect(PARENT_DOOR.resetNote).toMatch(/may not be a real mailbox/i)
    expect(OFFICE_DOOR.resetNote).toMatch(/not a real mailbox/i)
  })

  it('keeps the office door where every bookmark already points', () => {
    // Every ProtectedRoute redirect, every "Sign in" link on the website and
    // every bookmark lands on /login. Moving it would have broken all three to
    // gain nothing.
    expect(DOOR_PATH.office).toBe('/login')
    expect(DOOR_PATH.parents).toBe('/parents')
    expect(DOOR_PATH.operator).toBe('/operator')
  })

  it('builds the parent link from wherever the app is actually running', () => {
    // Hardcoding the host would be wrong on a Cloudflare preview and inside the
    // desktop shell, and wrong in the way nobody notices, because it would
    // still look like a link.
    expect(parentPortalLink()).toMatch(/\/parents$/)
    expect(parentPortalLink()).toContain(window.location.origin)
  })

  it('keeps the recovery pages selling nothing', () => {
    // /forgot and /reset serve all three audiences at once, so they are the one
    // place where a trial link would be a coin toss between useful and a trap.
    expect(RECOVERY_DOOR.offerTrial).toBe(false)
  })
})

/**
 * What a failed sign-in says.
 *
 * Every failure used to arrive as Supabase's own string, and the commonest one
 * by far is "Invalid login credentials": six words covering a mistyped
 * password, a mistyped address, an address belonging to nobody, and the right
 * person at the right door with the wrong account. The two ends of that range
 * need opposite actions.
 */
describe('what a failed sign-in says', () => {
  it('turns six unhelpful words into the next thing to do', () => {
    const parent = signInMessage('Invalid login credentials', PARENT_DOOR)
    expect(parent).toMatch(/school office/i)
    const office = signInMessage('Invalid login credentials', OFFICE_DOOR)
    expect(office).toMatch(/owner or principal/i)
    // Both name the two things that usually are actually wrong.
    for (const m of [parent, office]) {
      expect(m).toMatch(/capital letter/i)
      expect(m).toMatch(/space at the end/i)
    }
  })

  it('never says whether the address exists', () => {
    // It cannot know which of four things went wrong, and it must not guess:
    // "no such address" would confirm to anybody typing addresses whether they
    // exist. So it says what to do next and nothing about what is on file.
    const m = signInMessage('Invalid login credentials', PARENT_DOOR).toLowerCase()
    expect(m).not.toMatch(/no such|not found|does not exist|no account/)
  })

  it('separates "you are offline" from "your password is wrong"', () => {
    // These arrived as the same red box, and one of them is a reason to change
    // what you typed while the other is a reason not to.
    const m = signInMessage('Failed to fetch', OFFICE_DOOR)
    expect(m).toMatch(/could not reach the server/i)
    expect(m).toMatch(/nothing is wrong with your password/i)
  })

  it('passes anything it does not recognise through unchanged', () => {
    // A translator that swallows the unfamiliar is how a real diagnostic becomes
    // "something went wrong".
    expect(signInMessage('Database is in recovery mode', OFFICE_DOOR))
      .toBe('Database is in recovery mode')
  })
})

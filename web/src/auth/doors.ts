/**
 * THE THREE DOORS INTO THIS SOFTWARE, AND WHY THEY ARE PRESENTATION ONLY.
 *
 * WHAT WAS WRONG
 *
 * One sign-in page served an operator console, a school back office and a
 * parent portal, and it was written for none of them. It was written for a
 * school BUYER, which is a fourth person who is not signing in at all:
 *
 *   * The column beside the form said "One place for the office", showed a
 *     dashboard mockup, listed three selling points and printed a price table:
 *     "From Rs 2,000 a month. 14 days free. All modules included." A parent in
 *     Rawalpindi opening the portal to see whether their son's fee is paid was
 *     shown the price of the software their school buys. That is not noise, it
 *     is a category error: it tells a parent they are looking at a shop.
 *   * On a phone, where the column is hidden, the price line SURVIVED the
 *     collapse into a footer strip. So the one thing guaranteed to reach a
 *     parent on a phone was the price.
 *   * "New school? Start a free 14-day trial" was the only prominent
 *     alternative to the form, which makes it the thing a parent or teacher who
 *     cannot get in will press. And it works: they get a whole new school and
 *     become its owner. The vendor gets an orphan tenant in the console and the
 *     person believes they have signed in. create-school-owner's own header
 *     already documents this trap from the other direction.
 *   * "Use the email address your account was set up with" is true for an owner
 *     and useless for a parent, whose address was invented by the school office
 *     and may never have been told to them properly. The most useful sentence
 *     for the largest group of users, "ask the school office", was absent.
 *   * "Forgotten your password?" is a DEAD END for parents and most staff,
 *     because those addresses are frequently not real mailboxes, and the page
 *     did not say so. Offering a link that silently fails is worse than
 *     offering nothing.
 *   * Nothing said where you would land. Three different applications sit
 *     behind one form and the visitor had to already know which they were
 *     entitled to.
 *
 * THE RULE THIS FILE ESTABLISHES, AND IT IS THE WHOLE DESIGN
 *
 * A DOOR CHANGES WHAT THE PAGE SAYS AND NEVER WHAT IT CAN DO.
 *
 * Authentication is one mechanism. Supabase does not care which door you came
 * through, and it must not: nobody tells a parent to type a path, and a teacher
 * who bookmarks the parent link must not be turned away. A split that could
 * refuse the right person at the wrong door would be strictly worse than the
 * single page it replaced, because today they at least get in.
 *
 * So every door posts to the same sign-in, succeeds for anybody, and sends them
 * to "/" afterwards, where the routing that already exists decides by ROLE.
 * Sending them to the door's own destination instead would be the obvious
 * improvement and is a trap: a parent signing in at the operator door would be
 * pushed to /platform and meet the operator's refusal screen, which is the
 * exact wall this and 0115 exist to remove.
 *
 * WHAT DIFFERS BETWEEN DOORS is three sentences and a column: the heading, what
 * to do if you do not know your details, and what to do if you have forgotten
 * your password. Those are precisely the three the old page got wrong for two
 * of its three audiences.
 */

export type DoorColumn = 'selling' | 'portal' | 'office' | 'none'

export interface Door {
  id: 'office' | 'parents' | 'operator' | 'signup'
  /** Small caps label above the heading. Says which door this is. */
  eyebrow: string
  /** The one line of institutional copy in the support column. */
  line: string
  heading: string
  /** Under the heading. Says who the door is for, in one sentence. */
  intro: string
  /** What to do when you do not know your email address or password. */
  ifUnknown: string
  /**
   * Whether to offer the standard reset-by-email link as the FIRST remedy.
   *
   * False for parents and school staff, and that is not a design preference.
   * A school invents most of the addresses it hands out (see migration 0116),
   * so a reset email goes to a mailbox nobody owns. The honest first remedy is
   * the office, which since 0116 can actually look the password up.
   */
  resetFirst: boolean
  /** Extra sentence beside the reset link, when there is something true to add. */
  resetNote?: string
  /** The support column's content. 'none' renders no column at all. */
  column: DoorColumn
  /** The line under the form on narrow screens, where the column is gone. */
  footNote: string
  /** Offer "start a free trial". Only where a school BUYER might be standing. */
  offerTrial: boolean
}

/**
 * The office door, and the universal default.
 *
 * KEPT AT /login DELIBERATELY. Every bookmark, every redirect from
 * ProtectedRoute and every "Sign in" link on the website points here, and it
 * has to keep working for everybody, so this door alone carries a line pointing
 * a parent at theirs. One sentence, no gate, no wrong turn.
 */
export const OFFICE_DOOR: Door = {
  id: 'office',
  eyebrow: 'School office',
  heading: 'Sign in',
  intro: 'For the owner, the principal, the office and the teachers at your school.',
  ifUnknown:
    'Your owner or principal creates these. If you do not know either one, ask '
    + 'them: they can look up both.',
  resetFirst: true,
  resetNote:
    'If the address your school gave you is not a real mailbox, the email will '
    + 'not arrive. Ask the office instead.',
  column: 'office',
  footNote: 'From Rs 2,000 a month. 14 days free. All modules included.',
  offerTrial: true,
  line: 'The register, the fee book and the attendance sheet, in one place.',
}

/**
 * The parent door.
 *
 * The website's "Parent portal login" used to point at /portal, which requires
 * a session, so a signed-out parent was bounced to the office door and shown
 * the price of the software. It points here now.
 *
 * NO TRIAL LINK AND NO PRICE. A parent has nothing to buy, and the sentence
 * that replaces the trial link says so, because "am I being asked to pay for
 * this?" is a question parents genuinely ask the office.
 */
export const PARENT_DOOR: Door = {
  id: 'parents',
  eyebrow: 'Parent portal',
  heading: 'Parent sign in',
  intro: "See your children's fees, attendance and results.",
  ifUnknown:
    'Your school gives you these. If you do not know either one, ask the school '
    + 'office: they can look up both and tell you again.',
  resetFirst: false,
  resetNote:
    'The address your school gave you may not be a real mailbox, so a reset '
    + 'email may never arrive. The office is the quicker way back in.',
  column: 'portal',
  footNote: 'Free for parents. Ask the school office if you cannot get in.',
  offerTrial: false,
  line: "Your children's fees, attendance and results, whenever you want to look.",
}

/**
 * The vendor's own door.
 *
 * DELIBERATELY THE PLAINEST PAGE IN THE PRODUCT. No column, no mockup, no
 * price, no trial. It is not a shop window and there is nobody to persuade.
 * The one piece of copy it adds is the way out for a school owner who found
 * this address, because a person at the wrong door should be redirected by a
 * sentence and never by a refusal.
 */
export const OPERATOR_DOOR: Door = {
  id: 'operator',
  eyebrow: 'Operator console',
  heading: 'Operator sign in',
  intro: "For The School Manager's own staff.",
  ifUnknown: 'If you run a school rather than this service, use the school sign in.',
  resetFirst: true,
  column: 'none',
  footNote: '',
  offerTrial: false,
  line: '',
}

/**
 * Signing up, which is the one page where a school BUYER really is standing at
 * the keyboard, and therefore the one page the selling column belongs on.
 */
export const SIGNUP_DOOR: Door = {
  id: 'signup',
  eyebrow: 'Start a free trial',
  heading: 'Start your free trial',
  intro: '',
  ifUnknown: '',
  resetFirst: true,
  column: 'selling',
  footNote: 'From Rs 2,000 a month. 14 days free. All modules included.',
  offerTrial: false,
  line: 'The register, the fee book and the attendance sheet, in one place.',
}

/** For /forgot and /reset, which serve every audience and sell nothing. */
export const RECOVERY_DOOR: Door = {
  ...OFFICE_DOOR,
  eyebrow: '',
  column: 'office',
  offerTrial: false,
}

/**
 * A door's own address, for the links between them.
 *
 * ONE PLACE, because these strings appear in App.tsx's routes, in the sentences
 * on the doors themselves, in the copyable link a school sends its parents, and
 * in site/wire.js. Four copies of "/parents" is three chances to write
 * "/parent".
 */
export const DOOR_PATH: Record<Door['id'], string> = {
  office: '/login',
  parents: '/parents',
  operator: '/operator',
  signup: '/signup',
}

/**
 * The address a school sends its parents.
 *
 * WHY IT IS A FUNCTION AND NOT A CONSTANT. The app is deployed at whatever
 * hostname the school's copy runs on, and there is more than one: the
 * theschoolmanager.site app, a Cloudflare preview, and the desktop shell
 * pointed at either. A hardcoded host would be wrong on two of the three and
 * wrong in the way nobody notices, because it would still LOOK like a link.
 *
 * WHY IT EXISTS AT ALL. "Use your school's parent link" is worthless advice if
 * the school has no way to get the link. The office is handed it at the exact
 * moment it is needed: on the screen where they have just made a parent's
 * login, and again above the key ring where the passwords live.
 */
export function parentPortalLink(): string {
  const origin =
    typeof window === 'undefined' ? '' : window.location.origin.replace(/\/+$/, '')
  return `${origin}${DOOR_PATH.parents}`
}

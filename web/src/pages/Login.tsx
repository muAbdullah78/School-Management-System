import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '@/auth/AuthProvider'
import {
  AuthError,
  AuthLayout,
  AuthSpinner,
  authButton,
  authField,
  authLabel,
  AuthBusy,
} from '@/components/AuthLayout'
import { DOOR_PATH, OFFICE_DOOR, type Door } from '@/auth/doors'

/**
 * Turn what the auth service says into something a person can act on.
 *
 * WHY THIS IS WORTH A FUNCTION
 *
 * Every failure used to arrive as Supabase's own string, and for the commonest
 * one by far that string is "Invalid login credentials". Six words that cover a
 * mistyped password, a mistyped address, an address that belongs to nobody, and
 * a person who is at the right door with the wrong account entirely. The reader
 * cannot tell which, and the two ends of that range need opposite actions: try
 * again more carefully, or go and ask somebody.
 *
 * It cannot say WHICH, and it must not guess: telling somebody "no such
 * address" would confirm to anybody typing addresses whether they exist. So it
 * says what is worth doing next, and the next step is the one thing that
 * differs by door.
 */
export function signInMessage(raw: string, door: Door): string {
  const m = raw.toLowerCase()

  if (/invalid login credentials|invalid email or password/.test(m)) {
    return door.id === 'parents'
      ? 'That email address and password do not match. Check for a capital '
        + 'letter or a space at the end, and if it still will not work, ask the '
        + 'school office to read them out again: they can look up both.'
      : 'That email address and password do not match. Check for a capital '
        + 'letter or a space at the end. If it still will not work, your owner '
        + 'or principal can look up both for you.'
  }
  if (/email not confirmed/.test(m)) {
    return 'This account has not confirmed its email address yet. Open the link '
      + 'in the email we sent when the school signed up.'
  }
  if (/too many requests|rate limit/.test(m)) {
    return 'Too many attempts. Wait a minute and try once more.'
  }
  if (/failed to fetch|network|load failed|timeout/.test(m)) {
    return 'We could not reach the server. Check the internet connection and '
      + 'try again: nothing is wrong with your password.'
  }
  return raw
}

/**
 * ONE SIGN-IN, THREE DOORS.
 *
 * The critique that produced this, and the rule that a door changes what the
 * page SAYS and never what it can DO, are both in web/src/auth/doors.ts. The
 * short version: this page served an operator console, a school back office and
 * a parent portal while being written for a fourth person, a school buyer, who
 * is not signing in at all.
 *
 * ONE COMPONENT, NOT THREE PAGES. Three near-identical files is how the four
 * auth screens drifted apart before AuthLayout existed, and the whole reason
 * these doors are safe is that they share one form and one mechanism. Two
 * copies of a submit handler would be two chances for one of them to start
 * refusing somebody.
 *
 * EVERY DOOR NAVIGATES TO "/" AND THAT IS DELIBERATE. Sending the parent door
 * to /portal and the operator door to /platform is the obvious improvement and
 * it is a trap: a parent who signed in at the operator door would be pushed to
 * /platform and shown the operator's refusal screen, which is the exact wall
 * 0115 and LoginNotAttached exist to remove. "/" lets the routing that already
 * exists decide by ROLE, which is the only thing that can be right for
 * everybody.
 */
export function Login({ door = OFFICE_DOOR }: { door?: Door }) {
  const { signIn } = useAuth()
  const navigate = useNavigate()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    const { error } = await signIn(email.trim(), password)
    setBusy(false)
    if (error) {
      setError(signInMessage(error, door))
      return
    }
    navigate('/', { replace: true })
  }

  return (
    <AuthLayout door={door}>
      {/* THE DOOR SAYS WHICH DOOR IT IS, above the action. Three applications
          sit behind this form and nothing on the page used to say which one the
          visitor was standing in front of. */}
      {door.eyebrow && (
        <p className="flex items-center gap-2.5 text-[11.5px] font-bold uppercase tracking-[0.09em] text-cyan-700">
          <span aria-hidden="true" className="h-[2px] w-[18px] rounded-sm bg-cyan-500" />
          {door.eyebrow}
        </p>
      )}
      {/* The heading is the ACTION. The school's name is in the bar above,
          where it is rendered once for all the screens; repeating it here put
          the same words twice within 30px of each other. */}
      <h1 className={`text-2xl font-semibold tracking-[-0.015em] text-slate-900 ${door.eyebrow ? 'mt-3' : ''}`}>
        {door.heading}
      </h1>
      <p className="mt-1.5 text-base text-slate-500">{door.intro}</p>

      <form onSubmit={onSubmit} className="mt-7 space-y-4" aria-busy={busy}>
        <AuthBusy label={busy ? 'Signing in' : null} />
        <label className="block">
          <span className={authLabel}>Email</span>
          <input
            type="email"
            autoComplete="username"
            required
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className={authField}
          />
        </label>
        <label className="block">
          <span className={authLabel}>Password</span>
          <input
            type="password"
            autoComplete="current-password"
            required
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            className={authField}
          />
        </label>
        {error && <AuthError>{error}</AuthError>}
        <button type="submit" disabled={busy} className={authButton}>
          {busy && <AuthSpinner />}
          {busy ? 'Signing in' : 'Sign in'}
        </button>
      </form>

      {/* WHAT TO DO IF YOU DO NOT KNOW YOUR DETAILS, which is the most useful
          sentence on the page for the largest group of users and was missing.
          The old page said "Use the email address your account was set up
          with", which is true for an owner and useless for a parent, whose
          address was invented by the office and may never have been told to
          them properly. */}
      {(door.ifUnknown || door.noAccount) && (
        <div className="mt-5 space-y-2 rounded-lg bg-slate-50 px-3.5 py-3 text-sm text-slate-600">
          {door.ifUnknown && <p>{door.ifUnknown}</p>}
          {/* ONE BOX, TWO DIFFERENT PROBLEMS. Having an account and not
              knowing its details, and having no account at all, are not the
              same thing and need different answers. They were also going to
              end up as two boxes both saying "ask the school office", which
              reads as padding, so they share one. */}
          {door.noAccount && (
            <p className="border-t border-slate-200 pt-2 text-slate-700">
              {door.noAccount}
            </p>
          )}
        </div>
      )}

      {/* RECOVERY, AND HOW HONEST IT CAN BE.
          "Forgotten your password?" is a dead end for parents and for most
          staff: the addresses a school hands out are frequently not real
          mailboxes (migration 0116), so the reset email goes nowhere. Where
          that is the likely case the link is demoted and the note beside it
          says so, which is only possible to say because the office can now
          look the password up. */}
      <div className="mt-4 text-center text-sm">
        {/* ONE COLOUR, slate-500, ON EVERY DOOR.
            The first version demoted this link to slate-400 where a reset email
            is unlikely to arrive, which is #94A3B8 on white: 2.63:1, against
            the 4.5:1 body text needs. De-emphasising a link by making it
            unreadable is not de-emphasis, it is a defect, and this file already
            carries two measurements taken for exactly this reason. slate-500 is
            4.76:1 and reads as quiet.
            The demotion is carried by the sentence underneath instead, which is
            also the only thing that can carry it: the reason the link may not
            work is a fact about the address, not about the link. */}
        <Link to="/forgot" className="text-slate-500 hover:text-brand-700 hover:underline">
          Forgotten your password?
        </Link>
        {door.resetNote && (
          <p className="mx-auto mt-1.5 max-w-[38ch] text-xs leading-relaxed text-slate-500">
            {door.resetNote}
          </p>
        )}
      </div>

      <div className="mt-5 space-y-4 border-t border-slate-200 pt-5">
        {/* THE WAY-FINDING, AND IT USED TO BE 12px OF GREY TEXT.
            It sat at the bottom of a stack of four other lines, and the person
            it exists for is a parent who has been sent to the office door by
            their school, a bookmark, or the website's own Sign in link. Nobody
            finds a sentence that size, and the school reporting it was right.

            An OUTLINED button, full width: unmissable, a real 44px target on a
            phone, and still plainly subordinate to the filled Sign in button
            above, so an office clerk signing in every morning is not invited to
            press the wrong one.

            IT IS A SIGNPOST AND NEVER A CORRECTION. Every door signs anybody
            in, so this points at a page written for them rather than sending
            them somewhere they are required to go. The caption says so, which
            is what stops a parent who has already typed their password from
            wondering whether they have to start again. */}
        {door.otherDoor && (
          <div>
            <Link
              to={door.otherDoor.to}
              className="flex min-h-[44px] w-full items-center justify-center gap-2 rounded-lg
                         border border-slate-300 bg-white px-4 py-2.5 text-base font-semibold
                         text-brand-700 no-underline shadow-card
                         hover:border-brand-600 hover:bg-brand-50
                         focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500
                         focus-visible:ring-offset-2"
            >
              {door.otherDoor.label}
              <svg aria-hidden="true" viewBox="0 0 16 16" className="h-4 w-4 shrink-0" fill="none">
                <path d="M6 3.5 10.5 8 6 12.5" stroke="currentColor" strokeWidth="1.9"
                      strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </Link>
            {door.otherDoor.caption && (
              <p className="mt-2 text-center text-xs leading-relaxed text-slate-500">
                {door.otherDoor.caption}
              </p>
            )}
          </div>
        )}
        {/* LAST, AND QUIETEST, which is a change of order rather than of
            content. With the trial link above the parent button it was a line
            of 14px text sandwiched between two buttons, which reads as
            something nobody meant to put there. It is also the least urgent
            thing on this card: a school owner who needs to sign up arrived
            from a website whose largest control is Start free trial, so this
            is a convenience and not a path.

            THE TRIAL LINK IS ALSO THE TRAP THIS FIXES, and it is only removed
            where it is a trap. It was the only prominent alternative to the form, so
            it is what a parent or teacher who cannot get in presses. And it
            works: they get a whole new school and become its owner, the vendor
            gets an orphan tenant in the console, and the person believes they
            have signed in. */}
        {door.offerTrial && (
          <p className="text-center text-sm text-slate-500">
            New school?{' '}
            <Link to={DOOR_PATH.signup} className="font-medium text-brand-700 hover:underline">
              Start a free 14-day trial
            </Link>
          </p>
        )}

      </div>
    </AuthLayout>
  )
}

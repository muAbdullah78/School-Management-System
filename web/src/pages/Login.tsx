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
      {door.ifUnknown && (
        <p className="mt-5 rounded-lg bg-slate-50 px-3.5 py-3 text-sm text-slate-600">
          {door.ifUnknown}
        </p>
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

      <div className="mt-5 space-y-2 border-t border-slate-200 pt-5 text-center text-sm text-slate-500">
        {/* THE TRIAL LINK IS THE TRAP THIS FIXES, and it is only removed where
            it is a trap. It was the only prominent alternative to the form, so
            it is what a parent or teacher who cannot get in presses. And it
            works: they get a whole new school and become its owner, the vendor
            gets an orphan tenant in the console, and the person believes they
            have signed in. */}
        {door.offerTrial && (
          <p>
            New school?{' '}
            <Link to={DOOR_PATH.signup} className="font-medium text-brand-700 hover:underline">
              Start a free 14-day trial
            </Link>
          </p>
        )}
        {door.id === 'parents' && (
          <p>
            Your school has already signed up. There is nothing here for you to
            buy.
          </p>
        )}
        {/* THE WAY-FINDING, and it is a sentence rather than a gate.
            The office door has to keep working for everybody, because every
            bookmark and every redirect lands on it, so it points a parent at
            theirs without turning anybody away. The operator door points a
            school owner back, for the same reason in reverse. */}
        {door.id === 'office' && (
          <p className="text-xs">
            Are you a parent?{' '}
            <Link to={DOOR_PATH.parents} className="font-medium text-brand-700 hover:underline">
              The parent portal is here
            </Link>
            , and you can sign in above just the same.
          </p>
        )}
        {door.id === 'parents' && (
          <p className="text-xs">
            Work at the school?{' '}
            <Link to={DOOR_PATH.office} className="font-medium text-brand-700 hover:underline">
              Sign in for the office
            </Link>
            .
          </p>
        )}
        {door.id === 'operator' && (
          <p className="text-xs">
            Not the operator?{' '}
            <Link to={DOOR_PATH.office} className="font-medium text-brand-700 hover:underline">
              Sign in to your school
            </Link>
            .
          </p>
        )}
      </div>
    </AuthLayout>
  )
}

import type { Session } from '@supabase/supabase-js'

/**
 * The sign-in gate as a state machine, so the bug that shipped can be asserted.
 *
 * WHY THIS IS A MODULE AND NOT THREE useState CALLS
 *
 * "The desktop app asks for my password every time I open it" was a race
 * between two effects, and no test this project can run would have caught it:
 * there is no jsdom here, and the rendering harness uses renderToStaticMarkup,
 * which fires no effects at all. A pure function that merely restated the fix
 * would assert nothing about the real code path, so the real code path is now
 * this function and the sequence that produced the bug is a test case.
 *
 * THE BUG, precisely. There was one `loading` flag and the PROFILE effect
 * owned it. On a cold start:
 *
 *   1. mount: session null, loading true
 *   2. auth effect: getSession() starts, a promise, unresolved
 *   3. profile effect: sees no user id, sets loading FALSE
 *   4. render: loading false and session null, so the guard says "not signed
 *      in" and redirects to /login, replacing history
 *   5. getSession() resolves with the stored session, far too late
 *
 * Step 3 answers a question step 2 has not finished asking. A browser user
 * rarely noticed because they keep a tab open; the desktop shell cold-loads
 * the app root on every launch, so it happened every launch.
 *
 * THE RULE THIS MACHINE ENFORCES: nothing may report "not signed in" until the
 * stored session has been looked for and an answer, either way, is in.
 */

export type AuthGate = {
  /** The stored session has been looked for and the answer is known. */
  authReady: boolean
  /** A session exists and its profile row is in flight. */
  profileLoading: boolean
  session: Session | null
}

export const initialGate: AuthGate = {
  authReady: false,
  profileLoading: false,
  session: null,
}

export type AuthEvent =
  /** No Supabase client is configured, so there is nothing to restore. */
  | { type: 'no-client' }
  /** getSession() answered. `session` may legitimately be null. */
  | { type: 'restored'; session: Session | null }
  /** getSession() threw. Offline with an expired token does this. */
  | { type: 'restore-failed' }
  /** onAuthStateChange fired: a sign-in, a sign-out, a token refresh. */
  | { type: 'auth-change'; session: Session | null }
  /** Neither path settled in time. Never leave the user on a spinner. */
  | { type: 'watchdog' }
  | { type: 'profile-loading' }
  | { type: 'profile-settled' }

export function reduceGate(state: AuthGate, event: AuthEvent): AuthGate {
  switch (event.type) {
    case 'no-client':
      return { ...state, authReady: true, profileLoading: false, session: null }

    case 'restored':
      // authReady goes true even when the session is null: "there is no stored
      // session" is an answer, and it is the answer that lets the sign-in form
      // be shown honestly.
      return { ...state, authReady: true, session: event.session }

    case 'restore-failed':
      // No session to offer, but the question has been asked and answered as
      // far as it can be. Leaving authReady false here is what turned an
      // offline launch into a permanent "Loading" screen.
      return { ...state, authReady: true }

    case 'auth-change':
      // Arrives before `restored` on some connections, which is why it also
      // sets authReady. A null session here is a real sign-out and must clear
      // the stored one.
      return { ...state, authReady: true, session: event.session }

    case 'watchdog':
      // Only ever unsticks the gate. It must not touch the session, or a slow
      // but successful restore would be thrown away by a timer.
      return state.authReady ? state : { ...state, authReady: true }

    case 'profile-loading':
      return { ...state, profileLoading: true }

    case 'profile-settled':
      return { ...state, profileLoading: false }
  }
}

export type GateDecision =
  /** Show nothing yet. The answer is not in. */
  | 'wait'
  /** Signed in and known. Show the app. */
  | 'app'
  /** Genuinely not signed in. Show the form. */
  | 'sign-in'

export function decideGate(state: AuthGate): GateDecision {
  if (!state.authReady) return 'wait'
  if (!state.session) return 'sign-in'
  return state.profileLoading ? 'wait' : 'app'
}

/** What the rest of the app reads. Derived, so it cannot drift. */
export function gateIsLoading(state: AuthGate): boolean {
  return !state.authReady || state.profileLoading
}

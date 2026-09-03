import { describe, expect, it } from 'vitest'
import type { Session } from '@supabase/supabase-js'
import {
  decideGate,
  gateIsLoading,
  initialGate,
  reduceGate,
  type AuthEvent,
  type AuthGate,
} from './authGate'

// Only identity matters to the gate, so a stand-in is honest here and a real
// Session object would only add noise.
const SESSION = { user: { id: 'u1' } } as unknown as Session

const play = (...events: AuthEvent[]): AuthGate => events.reduce(reduceGate, initialGate)

describe('the cold start that shipped broken', () => {
  it('does NOT say "not signed in" before the stored session has been looked for', () => {
    // The exact sequence of the bug: the profile effect runs and settles while
    // getSession() is still in flight. The old code reported loading=false and
    // session=null here, which redirected a signed-in clerk to /login on every
    // launch of the desktop app.
    const state = play({ type: 'profile-settled' })
    expect(decideGate(state)).toBe('wait')
    expect(decideGate(state)).not.toBe('sign-in')
    expect(gateIsLoading(state)).toBe(true)
  })

  it('shows the app once the stored session arrives and its profile is in', () => {
    const state = play(
      { type: 'profile-settled' },
      { type: 'restored', session: SESSION },
      { type: 'profile-loading' },
      { type: 'profile-settled' },
    )
    expect(decideGate(state)).toBe('app')
    expect(gateIsLoading(state)).toBe(false)
  })

  it('waits while the profile of a restored session is still loading', () => {
    const state = play({ type: 'restored', session: SESSION }, { type: 'profile-loading' })
    expect(decideGate(state)).toBe('wait')
  })
})

describe('the honest sign-in cases', () => {
  it('asks for a password when there is genuinely no stored session', () => {
    const state = play({ type: 'restored', session: null })
    expect(decideGate(state)).toBe('sign-in')
    expect(gateIsLoading(state)).toBe(false)
  })

  it('asks for a password when no client is configured', () => {
    expect(decideGate(play({ type: 'no-client' }))).toBe('sign-in')
  })

  it('asks for a password rather than hanging when the restore throws', () => {
    // Offline with an expired token. The unhandled rejection here used to leave
    // authReady false for ever, which is a spinner with no way past it.
    expect(decideGate(play({ type: 'restore-failed' }))).toBe('sign-in')
  })

  it('asks for a password rather than hanging when nothing settles at all', () => {
    expect(decideGate(play({ type: 'watchdog' }))).toBe('sign-in')
  })
})

describe('event ordering', () => {
  it('accepts auth-change arriving BEFORE the restore resolves', () => {
    // Which of the two lands first depends on the network. A machine that only
    // handles one order works on a laptop and hangs on a phone.
    const state = play({ type: 'auth-change', session: SESSION }, { type: 'profile-settled' })
    expect(decideGate(state)).toBe('app')
  })

  it('is honest that a late restore of null would sign out a fresh sign-in', () => {
    // signIn fires auth-change immediately; a slow getSession() could then
    // answer "nothing stored" from a snapshot taken before the sign-in. The
    // machine reports what it was told, and the call site is responsible for
    // not dispatching a stale restore. Asserted so that coupling is visible
    // rather than accidental.
    const state = play(
      { type: 'auth-change', session: SESSION },
      { type: 'profile-settled' },
      { type: 'restored', session: null },
    )
    expect(decideGate(state)).toBe('sign-in')
  })

  it('signs the user out when auth-change reports null', () => {
    const state = play(
      { type: 'restored', session: SESSION },
      { type: 'profile-settled' },
      { type: 'auth-change', session: null },
    )
    expect(decideGate(state)).toBe('sign-in')
  })

  it('the watchdog never discards a session that did arrive', () => {
    const state = play({ type: 'restored', session: SESSION }, { type: 'watchdog' })
    expect(state.session).toBe(SESSION)
    expect(decideGate(state)).toBe('app')
  })

  it('the watchdog is a no-op once the answer is in', () => {
    const before = play({ type: 'restored', session: null })
    expect(reduceGate(before, { type: 'watchdog' })).toBe(before)
  })
})

describe('gateIsLoading', () => {
  it('is true before the answer and false after it', () => {
    expect(gateIsLoading(initialGate)).toBe(true)
    expect(gateIsLoading(play({ type: 'restored', session: null }))).toBe(false)
  })

  it('is true while a profile is in flight', () => {
    expect(
      gateIsLoading(play({ type: 'restored', session: SESSION }, { type: 'profile-loading' })),
    ).toBe(true)
  })
})

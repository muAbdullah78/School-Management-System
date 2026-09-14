// @vitest-environment jsdom
/**
 * A form must survive coming back to the tab.
 *
 * THE BUG THIS FILE EXISTS FOR, END TO END
 *
 * A clerk half way through admitting a student switched to another tab to read
 * a CNIC number off a photo, came back, and the form was empty. Nothing was
 * reported: no error, no failed request, no console warning. The chain was
 *
 *   1. supabase-js refreshes the access token when a hidden tab becomes
 *      visible again, and fires onAuthStateChange('TOKEN_REFRESHED', session).
 *   2. AuthProvider stored that session. Same person, new object.
 *   3. Its profile effect listed `session` as a dependency, and React compares
 *      dependencies by identity, so a new object re-ran it.
 *   4. Re-running set profileLoading, so the auth gate reported "loading".
 *   5. ProtectedRoute rendered "Loading…" INSTEAD OF its children, which
 *      unmounts the route tree and every useState under it.
 *   6. The profile came back, the tree mounted again, empty.
 *
 * Every step is reasonable on its own. The damage is only visible end to end,
 * which is why this test is end to end: a real AuthProvider, a real
 * ProtectedRoute, a real token refresh, and a child that counts its own mounts.
 *
 * A test that merely asserted the dependency array would pass against a
 * rewritten component that reintroduced the fault some other way.
 */
import { describe, expect, it, vi, afterEach } from 'vitest'
import { useState, useRef } from 'react'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { fakeSupabase, type FakeAuth } from './fakeSupabase'
import { AuthProvider } from '@/auth/AuthProvider'
import { ProtectedRoute } from '@/components/ProtectedRoute'

vi.mock('@/lib/config', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@/lib/config')>()),
  isConfigured: true,
}))

const auth: FakeAuth = {}
vi.mock('@/lib/supabase', () => {
  return {
    get supabase() {
      return current
    },
    requireSupabase() {
      return current
    },
  }
})

let current: any = null

function sessionFor(userId: string, token: string) {
  // Shaped like a real one in the two fields the provider reads, and a NEW
  // object every call, which is the whole point.
  return { access_token: token, user: { id: userId, email: 'head@school.pk' } }
}

/** Counts its own mounts, so an unmount cannot hide behind a re-render. */
function AdmissionForm({ mounts }: { mounts: { n: number } }) {
  const first = useRef(true)
  if (first.current) {
    first.current = false
    mounts.n += 1
  }
  const [name, setName] = useState('')
  return (
    <label>
      Student name
      <input value={name} onChange={(e) => setName(e.target.value)} />
    </label>
  )
}

afterEach(() => {
  cleanup()
  auth.emit = undefined
  auth.session = undefined
  auth.signOuts = undefined
  current = null
})

async function mountSignedIn(mounts: { n: number }) {
  auth.session = sessionFor('user-1', 'token-1')
  auth.signOuts = []
  current = fakeSupabase({
    auth,
    rows: {
      profiles: [
        { id: 'user-1', full_name: 'Head', role: 'principal', staff_id: null, school_id: 'school-1' },
      ],
    },
  })
  // A REAL <Routes> with a real /login destination, not a bare MemoryRouter.
  // ProtectedRoute redirects with <Navigate>, and a Navigate whose target
  // resolves to nothing re-renders and navigates again, forever. That is a
  // property of the test harness rather than of the app, but it is worth
  // stating: the sign-out path is only exercised honestly if there is
  // somewhere to land.
  render(
    <MemoryRouter initialEntries={['/students/new']}>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<div>Sign in</div>} />
          <Route
            path="/students/new"
            element={
              <ProtectedRoute>
                <AdmissionForm mounts={mounts} />
              </ProtectedRoute>
            }
          />
        </Routes>
      </AuthProvider>
    </MemoryRouter>,
  )
  // The form, not the loading line.
  await screen.findByLabelText('Student name')
}

describe('a form survives the tab losing and regaining focus', () => {
  it('keeps what was typed across a token refresh, and does not remount', async () => {
    const mounts = { n: 0 }
    await mountSignedIn(mounts)
    expect(mounts.n).toBe(1)

    const input = screen.getByLabelText('Student name') as HTMLInputElement
    fireEvent.change(input, { target: { value: 'Ayesha Khan' } })
    expect(input.value).toBe('Ayesha Khan')

    // The tab comes back. supabase-js refreshes the token and announces it.
    // A DIFFERENT object, the same person: exactly what production sends.
    await act(async () => {
      auth.emit?.('TOKEN_REFRESHED', sessionFor('user-1', 'token-2'))
    })

    // Before the fix this was '', because the input was a new element on a
    // newly mounted component.
    expect((screen.getByLabelText('Student name') as HTMLInputElement).value).toBe('Ayesha Khan')
    expect(mounts.n).toBe(1)
    expect(screen.queryByText(/Loading/)).toBeNull()
  })

  it('survives being told about the same session many times over', async () => {
    const mounts = { n: 0 }
    await mountSignedIn(mounts)
    const input = screen.getByLabelText('Student name') as HTMLInputElement
    fireEvent.change(input, { target: { value: 'Bilal Ahmed' } })

    // Twenty refreshes is roughly a working day of an hourly refresh plus a
    // teacher switching to WhatsApp and back a dozen times.
    for (let i = 0; i < 20; i++) {
      await act(async () => {
        auth.emit?.('TOKEN_REFRESHED', sessionFor('user-1', `token-${i}`))
      })
    }
    expect((screen.getByLabelText('Student name') as HTMLInputElement).value).toBe('Bilal Ahmed')
    expect(mounts.n).toBe(1)
  })

  it('still remounts when a DIFFERENT person signs in', async () => {
    const mounts = { n: 0 }
    await mountSignedIn(mounts)
    fireEvent.change(screen.getByLabelText('Student name'), { target: { value: 'not theirs' } })

    await act(async () => {
      auth.emit?.('SIGNED_IN', sessionFor('user-2', 'token-9'))
    })

    // The latch must not hold somebody else's half-typed form on screen. A new
    // user id is a real change and the remount is the correct behaviour.
    await waitFor(() => expect(mounts.n).toBe(2))
    expect((screen.getByLabelText('Student name') as HTMLInputElement).value).toBe('')
  })

  it('still redirects to the sign-in page on a real sign-out', async () => {
    const mounts = { n: 0 }
    await mountSignedIn(mounts)
    await act(async () => {
      auth.emit?.('SIGNED_OUT', null)
    })
    // The gate's DECISION is not latched, only its "I do not know yet" branch.
    await screen.findByText('Sign in')
    expect(screen.queryByLabelText('Student name')).toBeNull()
  })
})

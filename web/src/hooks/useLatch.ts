import { useRef } from 'react'

/**
 * Latches true the first time it is given true, and never returns to false.
 *
 * WHY A SCREEN MUST NOT BE ABLE TO UN-SHOW ITSELF
 *
 * Three components in this app stand between the router and a page:
 * ProtectedRoute, LicenceGate and SetupGate. Each was written the same way:
 *
 *     if (loading) return <div>Loading…</div>
 *     return <>{children}</>
 *
 * Read as a first render that is exactly right. Read as a component that runs
 * again every time anything upstream changes, it says something much stronger
 * and much worse: AT ANY MOMENT, for as long as this screen is open, if a
 * background load starts, TAKE THE SCREEN AWAY AND PUT IT BACK AFTERWARDS.
 *
 * React does not "put it back". It mounts a new one. Every useState in every
 * component below is reinitialised, so a half-filled admission form, a marks
 * grid with thirty numbers typed into it and a fee receipt mid-entry are all
 * blank, with no error and nothing to undo.
 *
 * The trigger in production was a token refresh firing on tab focus. That
 * specific cause is fixed at its source in AuthProvider. This hook exists so
 * that the NEXT thing which briefly sets a loading flag — a licence refetch, a
 * settings query falling out of the cache, a gate somebody adds next year —
 * cannot do it again. A gate should decide whether you may see a screen. It
 * should not get a second vote once you are looking at it.
 *
 * WHAT THIS DELIBERATELY DOES NOT LATCH: the decision itself. A licence that
 * expires while the tab is open must still replace the screen, and a sign-out
 * must still redirect. Only the "I do not know yet" branch is latched, and only
 * after the answer has been known once. Until then the loading screen is
 * honest and is shown.
 *
 * Writing a ref during render is safe here because the writes are idempotent:
 * for a given (value, resetKey) pair the result is the same however many times
 * render runs, so strict mode's double render produces the same answer and
 * there is no torn intermediate state to observe.
 */
export function useLatch(value: boolean, resetKey?: unknown): boolean {
  const latched = useRef(false)
  const key = useRef(resetKey)
  // A latch that could never be released would be its own bug. `resetKey` is
  // the identity the latch belongs to — in practice the signed-in user's id.
  // When a DIFFERENT person appears, the previous answer is not evidence about
  // them, so the gate goes back to not knowing and shows its loading state
  // again. That is what stops one user's half-typed screen being handed to the
  // next, which is the exact hazard a latch would otherwise introduce.
  if (key.current !== resetKey) {
    key.current = resetKey
    latched.current = false
  }
  if (value) latched.current = true
  return latched.current
}

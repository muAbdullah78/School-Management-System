import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { config } from '@/lib/config'

/**
 * What a signed-in person sees when their login belongs to no school.
 *
 * WHY THIS SCREEN EXISTS
 *
 * Because the screen that used to be here belonged to somebody else. A login
 * with no profile was assumed to be the vendor, so the app sent it to the
 * operator's console, which refused it with "Not available. This area is for
 * the system operator." and a Sign out button.
 *
 * Two real schools signed up and their owners got exactly that, on the click
 * that was supposed to open their new school. Signing in again gave the same
 * thing. Nothing on the screen said what had gone wrong, nothing said who to
 * ask, and it was not even true: they were not looking at an area reserved for
 * somebody else, they were looking at a half-finished signup.
 *
 * WHY IT IS THIS SHORT
 *
 * There are only three ways to be here and all three end in the same two
 * actions: check again, or ask a human. A password is not the problem, because
 * signing in worked. Retrying the signup is actively wrong, because it would
 * make a second school. So the screen says what is true, offers the one button
 * that can change the answer without a human, and names the two humans who can:
 * the school office for a teacher or parent, and us for an owner.
 *
 * The email address is shown because whoever fixes this needs it, and a person
 * reading their own address off the screen gets it right where one recalling it
 * over the telephone does not.
 */
export function LoginNotAttached() {
  const { session, signOut } = useAuth()
  const qc = useQueryClient()
  const [checking, setChecking] = useState(false)
  const email = session?.user?.email ?? null

  // Everything that decides this screen: the profile lookup in AuthProvider
  // keys off the session, and both gate questions are react-query keys. So a
  // school owner sitting on this page while we attach their profile from the
  // console can press one button and be inside, with no sign-out and no
  // instructions to relay over the telephone.
  async function checkAgain() {
    setChecking(true)
    try {
      await qc.invalidateQueries()
    } finally {
      setChecking(false)
    }
  }

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-6 shadow">
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-amber-100 text-2xl">
          🔑
        </div>
        <h1 className="mt-3 text-center text-lg font-semibold text-slate-800">
          Your login is not attached to a school yet
        </h1>
        <p className="mt-2 text-center text-sm text-slate-600">
          The password worked, so there is nothing wrong with your login. It just
          has no school against it, so there is nothing for us to open.
        </p>

        {email && (
          <p className="mt-4 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-center text-sm text-slate-700">
            Signed in as <span className="font-medium">{email}</span>
          </p>
        )}

        <div className="mt-4 space-y-3 text-sm text-slate-600">
          <p>
            <span className="font-medium text-slate-800">
              If you have just created a school:
            </span>{' '}
            do not sign up again, because that would make a second school. Press
            Check again below. If it still says this, send us the address above
            and we will finish it off within the hour.
          </p>
          <p>
            <span className="font-medium text-slate-800">
              If your school gave you this login:
            </span>{' '}
            ask the office to open Settings, then Users, and attach it to you
            there. It takes them a few seconds.
          </p>
        </div>

        <button
          onClick={() => void checkAgain()}
          disabled={checking}
          className="mt-5 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
        >
          {checking ? 'Checking…' : 'Check again'}
        </button>

        <div className="mt-3 flex items-center justify-between gap-2">
          <a
            href={`${config.siteUrl.replace(/\/+$/, "")}/contact`}
            className="rounded px-3 py-2 text-sm font-medium text-brand-700 hover:bg-brand-50"
          >
            Get in touch
          </a>
          <button
            onClick={() => void signOut()}
            className="rounded border border-slate-300 px-3 py-2 text-sm text-slate-700 hover:bg-slate-50"
          >
            Sign out
          </button>
        </div>
      </div>
    </div>
  )
}

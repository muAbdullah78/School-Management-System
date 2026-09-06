import { useQuery, useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'
import { useAuth } from '@/auth/AuthProvider'
import { config } from '@/lib/config'
import { myLoginState } from '@/lib/db'

/**
 * What a signed-in person sees when there is no school for them to open.
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
 * WHY IT ASKS THE DATABASE WHY
 *
 * There are two ways to be here and the right thing to say is different for
 * each. Nothing ever attached this login, which is the 0115 case; or somebody
 * closed it, which is a teacher who left or a parent whose access was removed.
 * The second used to be told their login was "not attached to a school yet"
 * and to ask the office to attach it, which sent the office looking for a
 * problem that was not there while the remedy, one Activate button, sat beside
 * that person's name on the Users screen. fn_my_login_state (0117) answers it.
 *
 * WHY IT IS OTHERWISE SHORT
 *
 * Because there are only two actions in any of these cases: check again, or ask
 * a human. A password is not the problem, because signing in worked. Retrying
 * the signup is actively wrong, because it would make a second school.
 */
export function LoginNotAttached() {
  const { session, signOut } = useAuth()
  const qc = useQueryClient()
  const [checking, setChecking] = useState(false)
  const email = session?.user?.email ?? null

  // retry: false, because the two states worth telling apart are both immediate
  // answers, and a screen that spins for three attempts before saying anything
  // is a screen somebody signs out of.
  const why = useQuery({
    queryKey: ['myLoginState', session?.user?.id],
    queryFn: myLoginState,
    retry: false,
  })
  const closed = why.data?.state === 'closed'
  const school = why.data?.school ?? null
  const isParent = why.data?.role === 'parent'

  // Everything that decides this screen: the profile lookup in AuthProvider
  // keys off the session, and both gate questions are react-query keys. So
  // somebody sitting on this page while the office switches their login back on
  // can press one button and be inside, with no sign-out and no instructions to
  // relay over the telephone.
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
          {closed ? '🔒' : '🔑'}
        </div>
        <h1 className="mt-3 text-center text-lg font-semibold text-slate-800">
          {closed
            ? 'This login has been switched off'
            : 'Your login is not attached to a school yet'}
        </h1>
        <p className="mt-2 text-center text-sm text-slate-600">
          {closed
            ? `Your password is correct and the login still exists${
                school ? ` at ${school}` : ''
              }. Somebody there has closed it, so there is nothing for us to open.`
            : 'The password worked, so there is nothing wrong with your login. It just has no school against it, so there is nothing for us to open.'}
        </p>

        {email && (
          <p className="mt-4 rounded border border-slate-200 bg-slate-50 px-3 py-2 text-center text-sm text-slate-700">
            Signed in as <span className="font-medium">{email}</span>
          </p>
        )}

        <div className="mt-4 space-y-3 text-sm text-slate-600">
          {closed ? (
            <p>
              {isParent
                ? 'Ask the school office to switch it back on. They open Settings, then Users, find you in the list and press Activate.'
                : 'Ask your owner or principal to switch it back on. They open Settings, then Users, find you in the list and press Activate.'}
            </p>
          ) : (
            <>
              <p>
                <span className="font-medium text-slate-800">
                  If you have just created a school:
                </span>{' '}
                do not sign up again, because that would make a second school.
                Press Check again below. If it still says this, send us the
                address above and we will finish it off within the hour.
              </p>
              <p>
                <span className="font-medium text-slate-800">
                  If your school gave you this login:
                </span>{' '}
                ask the office to open Settings, then Users, and attach it to you
                there. It takes them a few seconds.
              </p>
            </>
          )}
        </div>

        <button
          onClick={() => void checkAgain()}
          disabled={checking}
          className="mt-5 w-full rounded bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60"
        >
          {checking ? 'Checking…' : 'Check again'}
        </button>

        <div className="mt-3 flex items-center justify-between gap-2">
          {/* Not offered on the closed path. A person whose school switched
              their login off does not need the vendor; they need the office,
              and sending them to us adds a day to a five-second fix. */}
          {closed ? (
            <span />
          ) : (
            <a
              href={`${config.siteUrl.replace(/\/+$/, '')}/contact`}
              className="rounded px-3 py-2 text-sm font-medium text-brand-700 hover:bg-brand-50"
            >
              Get in touch
            </a>
          )}
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

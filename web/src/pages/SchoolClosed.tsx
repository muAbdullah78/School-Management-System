import { useAuth } from '@/auth/AuthProvider'
import type { Licence } from '@/lib/licence'

/**
 * What a parent or a teacher sees when the school has not renewed.
 *
 * WHY THIS IS A SEPARATE SCREEN FROM SubscriptionLocked
 *
 * SubscriptionLocked is written for the person who can fix it. It shows the
 * plan, the yearly and monthly price, the student count and a button that
 * downloads the school's entire database. Every one of those is right for an
 * owner and wrong for everybody else: a class teacher cannot pay the bill, has
 * no business seeing what the school is charged, and must not be handed an
 * export of every pupil, every fee and every mark in the building.
 *
 * It was shown to all of them, because the gate above it only asked whether a
 * profile existed.
 *
 * WHY IT SAYS SO LITTLE
 *
 * The one useful action here is "tell the office". Anything else invites a
 * teacher to relay a half-understood billing message to a principal, or a
 * parent to conclude the school has gone under. It names no price, blames
 * nobody, and does not say the word "unpaid": a transfer that is still clearing
 * looks exactly like this and the school does not deserve to be described that
 * way to its own parents.
 *
 * The commercial pressure is the screen existing at all. A principal who hears
 * from three parents in a morning renews that morning, which is the entire
 * point of closing the portal rather than only the office.
 */
export function SchoolClosed({ licence, audience }: {
  licence?: Licence
  audience: 'parent' | 'staff'
}) {
  const { signOut } = useAuth()
  const cancelled = licence?.status === 'cancelled'

  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-6 text-center shadow">
        <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-full bg-amber-100 text-2xl">
          🔒
        </div>
        <h1 className="mt-3 text-lg font-semibold text-slate-800">
          {audience === 'parent'
            ? 'The parent portal is closed at the moment'
            : 'This school’s account is paused'}
        </h1>

        <p className="mt-2 text-sm text-slate-600">
          {audience === 'parent'
            ? 'Your school has to renew its subscription before the portal can be used again. Please contact the school office: they can switch it back on straight away.'
            : 'The school’s subscription needs renewing before the app can be used again. Please tell the owner or principal; they can switch it back on straight away.'}
        </p>

        {/* The one thing everybody in this position is actually worried about,
            said before they have to ask. A parent who thinks the school has
            lost their child's fee record will ring the office in a state, and
            the office cannot see this screen to know why. */}
        <p className="mt-3 rounded border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900">
          Nothing has been lost. Every record is exactly where it was and comes
          straight back when the school renews.
        </p>

        {cancelled && (
          <p className="mt-3 text-xs text-slate-500">
            If you were told this school had closed, the office can confirm.
          </p>
        )}

        <button onClick={() => void signOut()}
          className="mt-5 w-full rounded border border-slate-300 px-3 py-2 text-sm text-slate-700 hover:bg-slate-50">
          Sign out
        </button>
      </div>
    </div>
  )
}

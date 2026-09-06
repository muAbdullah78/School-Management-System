import { useCallback, useState } from 'react'
import { checkLoginEmail, type EmailVerdict } from '@/lib/db'

/**
 * "Is this address free?", asked before the form is filled in rather than after
 * it is submitted.
 *
 * WHY THIS EXISTS
 *
 * A Pakistani private school does not collect working email addresses from
 * parents. It invents them, and names repeat: three schools in one city can
 * each decide the father of their Muhammad Ali is muhammadali786@gmail.com.
 * Login addresses are unique across the whole platform, so the second school to
 * try is refused.
 *
 * Refused AFTER the fact, though, and in the auth service's own words. The
 * clerk typed a name, an address, a password and a role, pressed Create, waited
 * for a round trip, and got back "A user with this email address has already
 * been registered", which does not say which of the four fields was wrong, or
 * whether the clash is inside their own school (where the answer is the key
 * ring) or somewhere else (where the answer is a different address).
 *
 * WHY IT IS ASKED ON BLUR AND NOT ON EVERY KEYSTROKE
 *
 * Because "muhammad" is not a question anybody wants answered. A check per
 * keystroke asks the database twenty times about an address that does not exist
 * yet and reports a fresh refusal after each letter, which trains the office to
 * ignore the line. One question per address typed, when they move to the next
 * field, is the same information at a twentieth of the noise.
 */
export function useEmailCheck() {
  const [verdict, setVerdict] = useState<EmailVerdict | null>(null)
  const [checking, setChecking] = useState(false)
  const [asked, setAsked] = useState<string | null>(null)

  const clear = useCallback(() => { setVerdict(null); setAsked(null) }, [])

  const check = useCallback(async (email: string) => {
    const e = email.trim().toLowerCase()
    // Nothing worth asking about, and nothing worth asking twice.
    if (!e || e === asked) return
    if (!/^\S+@\S+\.\S+$/.test(e)) { setVerdict(null); return }
    setChecking(true)
    setAsked(e)
    try {
      setVerdict(await checkLoginEmail(e))
    } catch {
      // A FAILED CHECK IS NOT A REFUSAL. This is a courtesy layer: the real
      // uniqueness rule lives in auth.users and will refuse the creation
      // anyway. Blocking the form because a convenience call timed out would
      // stop a school adding a teacher for no reason at all.
      setVerdict(null)
    } finally {
      setChecking(false)
    }
  }, [asked])

  return { verdict, checking, check, clear }
}

/**
 * The one line of feedback, in the three places a login address is typed.
 *
 * Renders nothing until there is something to say, so a form that has not been
 * touched does not carry an empty reassurance.
 */
export function EmailVerdictLine({ verdict, checking }: {
  verdict: EmailVerdict | null
  checking: boolean
}) {
  if (checking) {
    return <p className="mt-1 text-xs text-slate-500">Checking that address…</p>
  }
  if (!verdict) return null
  if (verdict.available) {
    return (
      <p className="mt-1 text-xs text-money-700">
        That address is free to use.
      </p>
    )
  }
  return (
    <p className="mt-1 rounded border border-due-200 bg-due-50 px-2 py-1.5 text-xs text-due-800">
      {verdict.message}
    </p>
  )
}

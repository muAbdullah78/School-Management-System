import { useMemo, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import {
  grantDiscount, type DiscountCode, type DiscountUse, type PlatformSchool,
} from '@/lib/platform'
import { fmtDate } from '@/lib/format'
import { needsReplace } from './rules'
import { FIELD, Problem, Shell } from './CodeForm'

const LABEL = 'block text-xs font-medium text-slate-600'

/**
 * Give a school a code: a deal agreed on the telephone, or a private code we
 * made for it.
 *
 * OURS TO GIVE, so the dates it can be taken up and the on-offer switch do not
 * apply, but the places still count and a reason is kept with the discount.
 * Only we can take off a code we gave.
 *
 * A SCHOOL'S LIVE CODE IS NEVER REPLACED BY ACCIDENT. A school has one money
 * code at a time, and giving a second one used to take the first off without a
 * word. If the school has one, it is shown here and nothing is given until
 * "Replace it" is ticked; the database refuses it otherwise, and if it refuses
 * because the roster here was out of date, the same choice appears.
 *
 * A code the school had before and lost comes back as it was, with the months
 * it still had, and the dialog says so before and after.
 */
export function GiveDialog({ code, schools, usage, onClose, onGiven }: {
  code: DiscountCode
  schools: PlatformSchool[]
  /** Every redemption, every code: what each school has now and had before. */
  usage: DiscountUse[]
  onClose: () => void
  onGiven: (message: string) => void
}) {
  const qc = useQueryClient()
  const [schoolId, setSchoolId] = useState(code.private ? (code.school_id ?? '') : '')
  const [reason, setReason] = useState('')
  const [replace, setReplace] = useState(false)
  const [askReplace, setAskReplace] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const list = useMemo(() => schools.filter((s) => !s.archived)
    .sort((a, b) => a.school_name.localeCompare(b.school_name)), [schools])
  const school = schools.find((s) => s.school_id === schoolId)
  const name = school?.school_name ?? code.school_name ?? 'This school'
  const trial = code.kind === 'trial_days'

  const theirs = usage.filter((u) => schoolId && u.school_id === schoolId)
  const prior = theirs.find((u) => u.code === code.code)
  const live = trial ? undefined
    : theirs.find((u) => u.state === 'active' && u.code !== code.code)

  // The database's refusals, said before the round trip. Its own sentence is
  // still what shows if it refuses something this list did not foresee.
  const blocker = !schoolId ? null
    : prior && !prior.removed_at
      ? (trial
        ? `${name} has already had its trial extended once with a code.`
        : `${name} already has ${code.code} on its subscription.`)
    : trial && theirs.some((u) => u.kind === 'trial_days')
      ? `${name} has already had its trial extended once with a code.`
    : trial && school && school.status !== 'trialing'
      ? `${name} is not in a running trial, so there is nothing to extend.`
    : !prior && code.max_redemptions != null && code.seats_taken >= code.max_redemptions
      ? `Every place on ${code.code} is taken (${code.seats_taken} of ${code.max_redemptions}).`
    : null

  const mustChoose = !!live || askReplace
  const reasonOk = reason.trim().length >= 8

  const give = useMutation({
    mutationFn: () => grantDiscount({
      schoolId, code: code.code, reason: reason.trim(), replace: mustChoose && replace,
    }),
    onSuccess: (r) => {
      for (const k of ['discounts', 'discountUsage', 'discountEvents', 'schoolDetail', 'platformSchools']) {
        void qc.invalidateQueries({ queryKey: [k] })
      }
      onGiven(r.restored
        ? `${r.code} is back on ${name}'s subscription, restored as it was before it came off.`
        : r.trial_ends_on
          ? `${name} has ${r.code}. Their trial now runs to ${fmtDate(r.trial_ends_on)}.`
          : `${name} now has ${r.code}: ${r.summary}.`)
    },
    onError: (e: Error) => {
      if (needsReplace(e)) setAskReplace(true)
      setErr(e.message)
    },
  })

  return (
    <Shell title={`Give ${code.code} to a school`} onClose={onClose}>
      <form className="mt-3 space-y-3"
        onSubmit={(e) => { e.preventDefault(); setErr(null); give.mutate() }}>
        <div className="rounded border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700">
          <span className="font-medium text-slate-900">{code.label}</span>: {code.summary}.
          <span className="mt-1 block text-xs text-slate-500">
            When we give a code its dates and its on-offer switch do not apply; its places
            still count. Only we can take it off again.
          </span>
        </div>

        {code.private ? (
          <div>
            <span className={LABEL}>School</span>
            <p className="py-1 text-sm text-slate-800">
              {name} <span className="text-slate-500">(the code was made for them, so only they can have it)</span>
            </p>
          </div>
        ) : (
          <label className="block">
            <span className={LABEL}>School</span>
            <select value={schoolId} autoFocus className={FIELD}
              onChange={(e) => {
                setSchoolId(e.target.value); setReplace(false); setAskReplace(false); setErr(null)
              }}>
              <option value="">Choose the school</option>
              {list.map((s) => (
                <option key={s.school_id} value={s.school_id}>
                  {s.school_name}{s.city ? `, ${s.city}` : ''}
                </option>
              ))}
            </select>
          </label>
        )}

        {prior?.removed_at && !blocker && (
          <p className="rounded border border-info-200 bg-info-50 px-3 py-2 text-sm text-info-800">
            {name} had {code.code} before; it came off on {fmtDate(prior.removed_at)}
            {prior.removed_reason ? ` (${prior.removed_reason})` : ''}. Giving it again restores
            it as it was
            {prior.duration === 'months' && prior.months_left != null
              ? `, with ${prior.months_left} month(s) left` : ''}.
          </p>
        )}

        {mustChoose && !blocker && (
          <div className="rounded border border-due-200 bg-due-50 px-3 py-2 text-sm text-due-900">
            {live ? (
              <p>
                {name} already has <span className="font-mono font-medium">{live.code}</span>
                {live.label ? ` (${live.label})` : ''}: {live.summary}.{' '}
                {live.granted_by_kind === 'platform' ? 'We gave it to them.' : 'They typed it in themselves.'}
              </p>
            ) : (
              <p>{name} already has a code on its subscription.</p>
            )}
            <label className="mt-2 inline-flex items-start gap-2">
              <input type="checkbox" checked={replace} onChange={(e) => setReplace(e.target.checked)}
                className="mt-0.5 h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500" />
              <span>
                Replace it. {live ? live.code : 'Their code'} comes off for good and {code.code} goes on.
              </span>
            </label>
          </div>
        )}

        <label className="block">
          <span className={LABEL}>Why they are getting it</span>
          <textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)}
            placeholder="Agreed on the phone with the principal for the new session"
            className={FIELD} />
          <span className="mt-0.5 block text-xs text-slate-400">
            Kept with the discount and in the log. At least 8 characters.
          </span>
        </label>

        {blocker && <Problem>{blocker}</Problem>}
        {err && !blocker && <Problem>{err}</Problem>}

        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-brand-500">
            Cancel
          </button>
          <button type="submit"
            disabled={give.isPending || !schoolId || !!blocker || !reasonOk || (mustChoose && !replace)}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 focus:outline-none focus:ring-2 focus:ring-brand-500 focus:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-60">
            {give.isPending ? 'Giving…'
              : prior?.removed_at ? 'Restore it'
              : mustChoose ? 'Replace and give' : 'Give it'}
          </button>
        </div>
      </form>
    </Shell>
  )
}

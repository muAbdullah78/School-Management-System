import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { requireSupabase } from '@/lib/supabase'
import { PageHeader, Card, CardTitle, Button, Field, inputClass, Badge } from '@/components/ui'
import { useAuth } from '@/auth/AuthProvider'
import { guideUrl } from '@/lib/config'

/**
 * Where a school writes the review that other schools read.
 *
 * WHY THIS SCREEN LOOKS SO CAUTIOUS. The whole value of a review page is that
 * a stranger believes it, and the fastest way to destroy that is one invented
 * review. So this screen cannot create one: every rule lives in 0093, in the
 * database, and this page only reports what the database already decided.
 *
 *   * fn_review_eligibility() decides whether the button exists at all, and
 *     names which condition is unmet so the screen can say so instead of
 *     showing a dead form.
 *   * fn_review_upsert() re-checks the same thing. A page cannot talk its way
 *     past it, and neither can a request typed by hand.
 *   * There is one review per school, so writing again edits the same one.
 *
 * THE 24 HOUR WINDOW IS SHOWN, NOT HIDDEN. A review is the author's alone for
 * a day: invisible, editable, withdrawable. Saying so is the difference between
 * "my words went straight onto a website" and "I can sleep on it", and it is
 * also why there is no approval queue: nobody here approves a review, so
 * nobody here can quietly bury one.
 */

const STARS = [1, 2, 3, 4, 5] as const

type Eligibility = {
  may_review: boolean
  reason: string | null
  role: string
  days_using: number
  days_needed: number
  receipts: number
  receipts_needed: number
  existing_review: string | null
}

type Review = {
  id: string
  rating: number
  title: string
  body: string
  display_mode: 'named' | 'city_only'
  status: 'live' | 'hidden' | 'withdrawn'
  publish_at: string
  hidden_reason: string | null
}

function StarPicker({
  value,
  onChange,
  disabled,
}: {
  value: number
  onChange: (n: number) => void
  disabled?: boolean
}) {
  return (
    // A RADIO GROUP, not five buttons. Five buttons are five tab stops with no
    // relationship, and a screen reader reads them as five unrelated controls
    // rather than as one question with five answers.
    <fieldset disabled={disabled} className="border-0 p-0">
      <legend className="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500">
        Your rating
      </legend>
      <div className="flex items-center gap-1">
        {STARS.map((n) => (
          <label
            key={n}
            className="cursor-pointer p-1"
            title={`${n} out of 5`}
          >
            <input
              type="radio"
              name="rating"
              value={n}
              checked={value === n}
              onChange={() => onChange(n)}
              className="sr-only peer"
            />
            <svg
              viewBox="0 0 24 24"
              className={`h-8 w-8 transition peer-focus-visible:ring-2 peer-focus-visible:ring-brand-500 ${
                n <= value ? 'text-due-500' : 'text-slate-300'
              }`}
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M12 2.6l2.9 5.9 6.5.9-4.7 4.6 1.1 6.4L12 17.4 6.2 20.4l1.1-6.4L2.6 9.4l6.5-.9z" />
            </svg>
            <span className="sr-only">{n} out of 5</span>
          </label>
        ))}
        <span className="ml-2 text-sm text-slate-500">
          {value ? `${value} out of 5` : 'Not chosen yet'}
        </span>
      </div>
    </fieldset>
  )
}

function NotYet({ e }: { e: Eligibility }) {
  const lines: Record<string, { title: string; body: string }> = {
    not_the_decision_maker: {
      title: 'Only the owner or the principal can write the school\'s review',
      body:
        'It goes out under the school\'s name, so it should be written by whoever decided to buy the software. Ask them to open this page.',
    },
    too_new: {
      title: `Not yet: ${e.days_using} of ${e.days_needed} days`,
      body:
        'A review written in the first week is a review of a demonstration. Come back once you have run a real month, and the page will be here.',
    },
    not_enough_use: {
      title: `Not yet: ${e.receipts} of ${e.receipts_needed} receipts`,
      body:
        'Take twenty fees for real first. This is also what stops anybody signing up and writing a review the same afternoon, which is the whole reason the reviews on the website are worth reading.',
    },
    no_school: {
      title: 'This account is not attached to a school',
      body: 'Sign in as a member of your school\'s staff.',
    },
  }
  const l = lines[e.reason ?? ''] ?? {
    title: 'Not available yet',
    body: 'The software will tell you here when it is.',
  }
  return (
    <Card>
      <CardTitle>Reviews</CardTitle>
      <h3 className="text-base font-semibold text-slate-900">{l.title}</h3>
      <p className="mt-2 max-w-[62ch] text-sm text-slate-600">{l.body}</p>
      {e.reason === 'too_new' || e.reason === 'not_enough_use' ? (
        <dl className="mt-4 grid max-w-sm grid-cols-2 gap-3 border-t border-slate-200 pt-4 text-sm">
          <div>
            <dt className="text-xs uppercase tracking-wide text-slate-500">Days using it</dt>
            <dd className="mt-0.5 font-semibold tabular-nums text-slate-900">
              {e.days_using} <span className="font-normal text-slate-500">of {e.days_needed}</span>
            </dd>
          </div>
          <div>
            <dt className="text-xs uppercase tracking-wide text-slate-500">Receipts issued</dt>
            <dd className="mt-0.5 font-semibold tabular-nums text-slate-900">
              {e.receipts} <span className="font-normal text-slate-500">of {e.receipts_needed}</span>
            </dd>
          </div>
        </dl>
      ) : null}
      <p className="mt-4 text-sm text-slate-500">
        In the meantime, <a className="text-brand-700 underline" href={guideUrl} target="_blank" rel="noopener">the handbook</a> covers
        everything the software does, and the office can ring us about anything it does not.
      </p>
    </Card>
  )
}

export function FeedbackPage() {
  const { profile } = useAuth()
  const qc = useQueryClient()
  const sb = requireSupabase()

  const elig = useQuery({
    queryKey: ['review-eligibility', profile?.school_id],
    queryFn: async (): Promise<Eligibility> => {
      const { data, error } = await sb.rpc('fn_review_eligibility')
      if (error) throw new Error(error.message)
      return data as Eligibility
    },
  })

  const existing = useQuery({
    queryKey: ['review-own', profile?.school_id],
    queryFn: async (): Promise<Review | null> => {
      const { data, error } = await sb
        .from('reviews')
        .select('id, rating, title, body, display_mode, status, publish_at, hidden_reason')
        .neq('status', 'withdrawn')
        .maybeSingle()
      if (error) throw new Error(error.message)
      return (data as Review) ?? null
    },
  })

  const [rating, setRating] = useState(0)
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [named, setNamed] = useState(true)
  const [loaded, setLoaded] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  // Fill the form from the existing review ONCE, so typing is not overwritten
  // by a refetch mid-sentence.
  if (!loaded && existing.data) {
    setRating(existing.data.rating)
    setTitle(existing.data.title)
    setBody(existing.data.body)
    setNamed(existing.data.display_mode === 'named')
    setLoaded(true)
  }

  const save = useMutation({
    mutationFn: async () => {
      const { error } = await sb.rpc('fn_review_upsert', {
        p_rating: rating,
        p_title: title,
        p_body: body,
        p_display_mode: named ? 'named' : 'city_only',
      })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setErr(null)
      void qc.invalidateQueries({ queryKey: ['review-own'] })
      void qc.invalidateQueries({ queryKey: ['review-eligibility'] })
    },
    onError: (e: Error) => setErr(e.message),
  })

  const withdraw = useMutation({
    mutationFn: async () => {
      const { error } = await sb.rpc('fn_review_withdraw')
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setErr(null)
      setRating(0)
      setTitle('')
      setBody('')
      setLoaded(true)
      void qc.invalidateQueries({ queryKey: ['review-own'] })
    },
    onError: (e: Error) => setErr(e.message),
  })

  if (elig.isLoading) {
    return <div className="p-2 text-sm text-slate-500">Loading</div>
  }
  if (elig.error) {
    return <div className="p-2 text-sm text-danger-700">{(elig.error as Error).message}</div>
  }

  // Not `elig.data!`. If the eligibility read comes back empty the honest
  // answer is that we cannot tell yet, not a blank screen.
  const e = elig.data
  if (!e) {
    return (
      <div className="p-2 text-sm text-slate-500">
        We could not check whether this school can write a review yet. Try again in
        a moment.
      </div>
    )
  }
  const review = existing.data ?? null
  const inWindow = review ? new Date(review.publish_at).getTime() > Date.now() : false
  const tooShort = title.trim().length < 4 || body.trim().length < 40 || rating < 1

  return (
    <div className="space-y-4">
      <PageHeader
        title="Tell other schools"
        subtitle="Your review, on the website, for school owners deciding whether to ring us."
      />

      {!e.may_review && !review ? (
        <NotYet e={e} />
      ) : (
        <>
          {review ? (
            <Card>
              <CardTitle
                right={
                  review.status === 'hidden' ? (
                    <Badge tone="danger">Hidden</Badge>
                  ) : inWindow ? (
                    <Badge tone="due">Not public yet</Badge>
                  ) : (
                    <Badge tone="money">On the website</Badge>
                  )
                }
              >
                Your review
              </CardTitle>
              {review.status === 'hidden' ? (
                <p className="max-w-[64ch] text-sm text-slate-600">
                  We have taken this off the website, recorded as{' '}
                  <b>{review.hidden_reason?.replace(/_/g, ' ')}</b>. A review is only ever
                  removed for something like spam or naming a child, never for being
                  critical. If you think this is wrong, ring us: the decision and the reason
                  are both in our own audit log, and we can put it back.
                </p>
              ) : inWindow ? (
                <p className="max-w-[64ch] text-sm text-slate-600">
                  It goes on the website at{' '}
                  <b>{new Date(review.publish_at).toLocaleString('en-PK')}</b>. Until then
                  nobody outside your school can see it, and you can change it or take it
                  down as often as you like. Editing it starts the day again.
                </p>
              ) : (
                <p className="max-w-[64ch] text-sm text-slate-600">
                  This is live on the website now. You can still change it or take it down at
                  any time, and an edit takes it off the site for a day before it reappears.
                </p>
              )}
            </Card>
          ) : null}

          <Card>
            <CardTitle>{review ? 'Change what it says' : 'Write it'}</CardTitle>

            <div className="space-y-4">
              <StarPicker value={rating} onChange={setRating} />

              <Field label="One line summary" hint="What another school owner would most want to know. 4 to 90 characters.">
                <input
                  className={inputClass}
                  maxLength={90}
                  value={title}
                  onChange={(ev) => setTitle(ev.target.value)}
                  placeholder="Our clerk stopped dreading the first of the month"
                />
              </Field>

              <Field
                label="The review"
                hint={`What you actually use it for, and what you would change. ${body.trim().length} of at least 40 characters.`}
              >
                <textarea
                  className={`${inputClass} min-h-[160px]`}
                  maxLength={1800}
                  value={body}
                  onChange={(ev) => setBody(ev.target.value)}
                  placeholder="We ran one class in parallel with the register for two weeks before moving the whole school over."
                />
              </Field>

              <fieldset className="border-0 p-0">
                <legend className="mb-1 block text-xs font-medium uppercase tracking-wide text-slate-500">
                  How it is signed
                </legend>
                <div className="space-y-2">
                  <label className="flex items-start gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      name="display"
                      checked={named}
                      onChange={() => setNamed(true)}
                      className="mt-1"
                    />
                    <span>
                      With our school's name and city. <span className="text-slate-500">Worth
                      more to whoever reads it, because it can be checked.</span>
                    </span>
                  </label>
                  <label className="flex items-start gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      name="display"
                      checked={!named}
                      onChange={() => setNamed(false)}
                      className="mt-1"
                    />
                    <span>
                      Just the city. <span className="text-slate-500">Shown as "A school in
                      your city". Your name is never published either way.</span>
                    </span>
                  </label>
                </div>
              </fieldset>

              {err ? (
                <p role="alert" className="rounded-lg border border-danger-100 bg-danger-50 p-3 text-sm text-danger-700">
                  {err}
                </p>
              ) : null}

              <div className="flex flex-wrap items-center gap-2 border-t border-slate-200 pt-4">
                <Button
                  onClick={() => save.mutate()}
                  disabled={tooShort || save.isPending}
                >
                  {save.isPending ? 'Saving' : review ? 'Save the change' : 'Post it'}
                </Button>
                {review ? (
                  <Button
                    tone="danger"
                    variant="soft"
                    onClick={() => withdraw.mutate()}
                    disabled={withdraw.isPending}
                  >
                    {withdraw.isPending ? 'Taking it down' : 'Take it down'}
                  </Button>
                ) : null}
                <p className="text-xs text-slate-500">
                  Nobody here approves it. It appears on the website by itself a day after
                  you post it.
                </p>
              </div>
            </div>
          </Card>
        </>
      )}
    </div>
  )
}

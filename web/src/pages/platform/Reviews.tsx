import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { requireSupabase } from '@/lib/supabase'

/**
 * The operator's view of customer reviews, and the deliberately small set of
 * things it can do to one.
 *
 * THERE IS NO APPROVE BUTTON, and its absence is the design. A review publishes
 * itself 24 hours after it is written. If publishing required an operator, then
 * every review we did not like could sit in a queue for ever and the average on
 * the website would be a number we chose. Nothing on this screen can create a
 * review, edit a rating, change a word, or make one public sooner.
 *
 * WHAT IT CAN DO is take one down for abuse, naming which kind, and put it
 * back. The categories come from a CHECK constraint in 0093 and there is no
 * value in them meaning "critical" or "low rating": that is a fact about the
 * schema rather than a promise about this screen. Every hide and every restore
 * writes an operator_actions row with the rating attached, so hiding a run of
 * one-star reviews is a pattern visible in the log without reading a single
 * review.
 *
 * The distribution at the top is here for us, not for the website: if the
 * public average ever drifts from the shape of the ratings underneath it,
 * something is wrong and this is where it shows.
 */

type Row = {
  id: string
  school_id: string | null
  school_name: string
  city: string | null
  author_name: string | null
  rating: number
  title: string
  body: string
  display_mode: 'named' | 'city_only'
  status: 'live' | 'hidden' | 'withdrawn'
  publish_at: string
  is_public: boolean
  hidden_reason: string | null
  hidden_note: string | null
  hidden_at: string | null
  created_at: string
}

/* The only reasons a review may come down. Mirrors the CHECK in 0093, and the
   two marked `needsNote` are the two that are a judgement about the reviewer
   rather than about the text, which is why the database demands an
   explanation for them. */
const REASONS: Array<{ v: string; label: string; needsNote?: boolean }> = [
  { v: 'spam', label: 'Spam or an advertisement' },
  { v: 'abusive_language', label: 'Abusive language' },
  { v: 'names_a_child', label: 'Names a child' },
  { v: 'names_a_person', label: 'Names and attacks a person' },
  { v: 'not_a_customer', label: 'Not from this school', needsNote: true },
  { v: 'off_topic', label: 'Not about the software', needsNote: true },
]

const FIELD =
  'rounded border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

function Stars({ n }: { n: number }) {
  return (
    <span className="whitespace-nowrap" title={`${n} out of 5`}>
      <span aria-hidden="true" className="text-amber-500">{'★'.repeat(n)}</span>
      <span aria-hidden="true" className="text-slate-300">{'★'.repeat(5 - n)}</span>
      <span className="sr-only">{n} out of 5</span>
    </span>
  )
}

export function Reviews() {
  const qc = useQueryClient()
  const sb = requireSupabase()
  const [open, setOpen] = useState<string | null>(null)
  const [reason, setReason] = useState('spam')
  const [note, setNote] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const rows = useQuery({
    queryKey: ['platform-reviews'],
    queryFn: async (): Promise<Row[]> => {
      const { data, error } = await sb.rpc('fn_platform_reviews', { p_limit: 300 })
      if (error) throw new Error(error.message)
      return (data ?? []) as Row[]
    },
  })

  const summary = useQuery({
    queryKey: ['reviews-summary'],
    queryFn: async () => {
      const { data, error } = await sb.from('reviews_summary').select('*').maybeSingle()
      if (error) throw new Error(error.message)
      return data as {
        total: number
        average: number | null
        five: number
        four: number
        three: number
        two: number
        one: number
      } | null
    },
  })

  const hide = useMutation({
    mutationFn: async (id: string) => {
      const { error } = await sb.rpc('fn_platform_review_hide', {
        p_id: id,
        p_reason: reason,
        p_note: note.trim() || null,
      })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setErr(null)
      setOpen(null)
      setNote('')
      void qc.invalidateQueries({ queryKey: ['platform-reviews'] })
      void qc.invalidateQueries({ queryKey: ['reviews-summary'] })
    },
    onError: (e: Error) => setErr(e.message),
  })

  const restore = useMutation({
    mutationFn: async (id: string) => {
      const why = window.prompt(
        'Why is this going back on the website? Recorded in the operator log, at least 10 characters.',
      )
      if (!why) return
      const { error } = await sb.rpc('fn_platform_review_restore', { p_id: id, p_note: why })
      if (error) throw new Error(error.message)
    },
    onSuccess: () => {
      setErr(null)
      void qc.invalidateQueries({ queryKey: ['platform-reviews'] })
      void qc.invalidateQueries({ queryKey: ['reviews-summary'] })
    },
    onError: (e: Error) => setErr(e.message),
  })

  const s = summary.data
  const list = rows.data ?? []

  return (
    <div className="space-y-3">
      {/* The public numbers, for us. A published average that does not match
          the shape of the ratings under it is the signal that something has
          gone wrong, and this is the only place it would be visible. */}
      <div className="rounded-lg border border-slate-200 bg-white p-3">
        <div className="flex flex-wrap items-center justify-between gap-3">
          <div className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            What the website shows
          </div>
          <div className="text-sm text-slate-600">
            {s && s.total > 0 ? (
              <>
                <b className="tabular-nums text-slate-900">{Number(s.average).toFixed(2)}</b> out of 5
                {' '}from <b className="tabular-nums">{s.total}</b> published review
                {s.total === 1 ? '' : 's'}
              </>
            ) : (
              'No published reviews yet, so the website shows none and claims no rating.'
            )}
          </div>
        </div>
        {s && s.total > 0 ? (
          <div className="mt-3 space-y-1">
            {([['5', s.five], ['4', s.four], ['3', s.three], ['2', s.two], ['1', s.one]] as const).map(
              ([label, n]) => (
                <div key={label} className="flex items-center gap-2 text-xs text-slate-600">
                  <span className="w-3 tabular-nums">{label}</span>
                  <span className="h-2 flex-1 overflow-hidden rounded bg-slate-100">
                    <span
                      className="block h-full rounded bg-amber-400"
                      style={{ width: `${s.total ? (n / s.total) * 100 : 0}%` }}
                    />
                  </span>
                  <span className="w-8 text-right tabular-nums">{n}</span>
                </div>
              ),
            )}
          </div>
        ) : null}
      </div>

      {err ? (
        <p role="alert" className="rounded-lg border border-red-100 bg-red-50 p-3 text-sm text-red-700">
          {err}
        </p>
      ) : null}

      {rows.isLoading ? <div className="p-2 text-sm text-slate-500">Loading</div> : null}
      {rows.error ? (
        <div className="p-2 text-sm text-red-700">{(rows.error as Error).message}</div>
      ) : null}

      {!rows.isLoading && list.length === 0 ? (
        <div className="rounded-lg border border-slate-200 bg-white p-6 text-sm text-slate-600">
          No school has written a review yet. A school can only write one after 21 days and
          20 real receipts, so this stays empty until somebody has genuinely used the
          software for a term.
        </div>
      ) : null}

      {list.map((r) => (
        <div key={r.id} className="rounded-lg border border-slate-200 bg-white p-3">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <Stars n={r.rating} />
                <span className="font-medium text-slate-900">{r.title}</span>
              </div>
              <div className="mt-1 text-xs text-slate-500">
                {r.school_name}
                {r.city ? `, ${r.city}` : ''}
                {r.author_name ? ` · written by ${r.author_name}` : ''}
                {r.display_mode === 'city_only' ? ' · published as "A school"' : ''}
                {r.school_id === null ? ' · school purged, review kept' : ''}
              </div>
            </div>
            <div className="flex shrink-0 flex-wrap items-center gap-2">
              {r.status === 'withdrawn' ? (
                <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs text-slate-600">
                  Withdrawn by the school
                </span>
              ) : r.status === 'hidden' ? (
                <span className="rounded-full bg-red-50 px-2 py-0.5 text-xs text-red-700">
                  Hidden: {r.hidden_reason?.replace(/_/g, ' ')}
                </span>
              ) : r.is_public ? (
                <span className="rounded-full bg-emerald-50 px-2 py-0.5 text-xs text-emerald-700">
                  On the website
                </span>
              ) : (
                <span className="rounded-full bg-amber-50 px-2 py-0.5 text-xs text-amber-800">
                  Public {new Date(r.publish_at).toLocaleString('en-PK')}
                </span>
              )}
              {r.status === 'hidden' ? (
                <button
                  onClick={() => restore.mutate(r.id)}
                  className="rounded border border-slate-300 px-2 py-1 text-xs hover:bg-slate-50"
                >
                  Put it back
                </button>
              ) : r.status === 'live' ? (
                <button
                  onClick={() => {
                    setOpen(open === r.id ? null : r.id)
                    setErr(null)
                  }}
                  className="rounded border border-slate-300 px-2 py-1 text-xs hover:bg-slate-50"
                >
                  Take it down
                </button>
              ) : null}
            </div>
          </div>

          <p className="mt-2 whitespace-pre-wrap text-sm text-slate-700">{r.body}</p>

          {r.hidden_note ? (
            <p className="mt-2 rounded bg-slate-50 p-2 text-xs text-slate-600">
              Our note: {r.hidden_note}
            </p>
          ) : null}

          {open === r.id ? (
            <div className="mt-3 rounded border border-amber-200 bg-amber-50 p-3">
              <p className="text-sm font-medium text-slate-900">
                Why is this coming down?
              </p>
              <p className="mt-1 max-w-[70ch] text-xs text-slate-600">
                A review is never removed for being critical, and there is no reason on this
                list that means that. Whatever you pick is written to the operator log
                alongside the rating, so a run of hidden one-star reviews is visible to
                anybody reading the log.
              </p>
              <div className="mt-2 flex flex-wrap items-center gap-2">
                <select value={reason} onChange={(e) => setReason(e.target.value)} className={FIELD}>
                  {REASONS.map((x) => (
                    <option key={x.v} value={x.v}>
                      {x.label}
                    </option>
                  ))}
                </select>
                <input
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder={
                    REASONS.find((x) => x.v === reason)?.needsNote
                      ? 'Required: what did you check?'
                      : 'Optional note'
                  }
                  className={`${FIELD} min-w-[18rem] flex-1`}
                />
                <button
                  onClick={() => hide.mutate(r.id)}
                  disabled={hide.isPending}
                  className="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
                >
                  {hide.isPending ? 'Taking it down' : 'Take it down'}
                </button>
                <button
                  onClick={() => setOpen(null)}
                  className="rounded px-2 py-1.5 text-sm text-slate-600 hover:bg-white"
                >
                  Cancel
                </button>
              </div>
            </div>
          ) : null}
        </div>
      ))}
    </div>
  )
}

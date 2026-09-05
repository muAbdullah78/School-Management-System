/**
 * What the school sends to parents, and which of it goes out at all.
 *
 * message_templates has existed since migration 0034 with a body and an
 * `enabled` flag, seeded per school, and nothing in the app ever read or wrote
 * it. So the exact words sent to three hundred parents were fixed by a
 * migration, and a school that wanted to stop one of the five message types had
 * no way to do it.
 *
 * This is their "Automation Settings" screen: per event, an editable body, the
 * merge tags it may use, and a toggle. Two differences from theirs, both
 * deliberate:
 *
 *   * It is WhatsApp, not SMS. Same trigger, same tags, no credits.
 *   * There is a live preview with sample values. Their screen lists supported
 *     tags in red text under the box and leaves you to imagine the result; a
 *     school editing a message that goes to hundreds of parents should be able
 *     to read it first.
 */
import { useEffect, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listMessageSettings, saveMessageSetting, resetMessageTemplate, previewMessage,
  type MessageSetting,
} from '@/lib/db'
import { useSchoolName } from '@/hooks/useSchoolName'
import { useAuth } from '@/auth/AuthProvider'

export function MessageSettings() {
  const { profile } = useAuth()
  const canEdit = !!profile && ['owner', 'principal'].includes(profile.role)
  const list = useQuery({ queryKey: ['messageSettings'], queryFn: listMessageSettings })

  return (
    <div className="max-w-3xl">
      <h3 className="text-sm font-semibold text-slate-800">Messages sent to parents</h3>
      <p className="mt-1 text-sm text-slate-600">
        Every message the school sends over WhatsApp. Change the wording, or switch one off
        completely. Nothing is sent automatically, so these are the words that appear in the box
        when a receipt or reminder is opened.
      </p>
      {!canEdit && (
        <p className="mt-2 text-xs text-slate-500">
          Only the owner or principal can change these. You can see what goes out.
        </p>
      )}

      {list.isLoading && <p className="mt-4 text-sm text-slate-400">Loading…</p>}
      {list.isError && (
        <p className="mt-4 text-sm text-red-600">{(list.error as Error).message}</p>
      )}

      <div className="mt-4 space-y-4">
        {list.data?.map((t) => (
          <TemplateCard key={t.template_key} t={t} canEdit={canEdit} />
        ))}
      </div>
    </div>
  )
}

function TemplateCard({ t, canEdit }: { t: MessageSetting; canEdit: boolean }) {
  const qc = useQueryClient()
  const schoolName = useSchoolName()
  const [body, setBody] = useState(t.body)
  const [saved, setSaved] = useState(false)

  // Re-sync when the query refetches, or an edit made elsewhere would be hidden
  // behind stale local state.
  useEffect(() => {
    setBody(t.body)
  }, [t.body])

  const invalidate = () => qc.invalidateQueries({ queryKey: ['messageSettings'] })

  const save = useMutation({
    mutationFn: () => saveMessageSetting(t.template_key, { body }),
    onSuccess: () => {
      setSaved(true)
      invalidate()
      window.setTimeout(() => setSaved(false), 2500)
    },
  })

  const toggle = useMutation({
    mutationFn: (enabled: boolean) => saveMessageSetting(t.template_key, { enabled }),
    onSuccess: invalidate,
  })

  const restore = useMutation({
    mutationFn: () => resetMessageTemplate(t.template_key),
    onSuccess: (original) => {
      setBody(original)
      invalidate()
    },
  })

  const dirty = body !== t.body

  // A tag that is not in this template's supported list will reach the parent
  // as literal "{whatever}", so it is worth naming before they send it.
  const unknown = [...body.matchAll(/\{([a-z_]+)\}/g)]
    .map((m) => m[1])
    .filter((k, i, a) => a.indexOf(k) === i && !t.tags.includes(k))

  return (
    <div
      className={`rounded-lg border bg-white p-4 ${
        t.enabled ? 'border-slate-200' : 'border-slate-200 bg-slate-50'
      }`}
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div>
          <div className="text-sm font-medium text-slate-800">{t.label}</div>
          <div className="text-xs text-slate-400">{t.template_key}</div>
        </div>
        <label className="flex items-center gap-2 text-xs text-slate-600">
          <input
            type="checkbox"
            checked={t.enabled}
            disabled={!canEdit || toggle.isPending}
            onChange={(e) => toggle.mutate(e.target.checked)}
            className="h-4 w-4"
          />
          {t.enabled ? 'On' : 'Off'}
        </label>
      </div>

      {!t.enabled && (
        <p className="mt-2 rounded bg-due-50 px-2 py-1 text-xs text-due-800">
          Switched off. This message is never queued, so it will not appear under WhatsApp at all.
        </p>
      )}

      <textarea
        value={body}
        onChange={(e) => setBody(e.target.value)}
        disabled={!canEdit}
        rows={4}
        className="mt-3 w-full rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none disabled:bg-slate-50"
      />

      <div className="mt-2 flex flex-wrap items-center gap-1.5 text-xs">
        <span className="text-slate-500">Available:</span>
        {t.tags.map((tag) => (
          <button
            key={tag}
            type="button"
            disabled={!canEdit}
            onClick={() => setBody((b) => `${b}{${tag}}`)}
            title={`Insert {${tag}}`}
            className="rounded bg-slate-100 px-1.5 py-0.5 font-mono text-slate-600 hover:bg-brand-50 hover:text-brand-700 disabled:hover:bg-slate-100"
          >
            {`{${tag}}`}
          </button>
        ))}
      </div>

      {unknown.length > 0 && (
        <p className="mt-2 text-xs text-danger-600">
          {unknown.map((u) => `{${u}}`).join(', ')}{' '}
          {unknown.length === 1 ? 'is not available here' : 'are not available here'}. The parent
          would receive it as written.
        </p>
      )}

      <div className="mt-3 rounded bg-slate-50 p-3">
        <div className="text-xs font-medium uppercase tracking-wide text-slate-500">
          What a parent sees
        </div>
        <p className="mt-1 whitespace-pre-wrap text-sm text-slate-700">
          {previewMessage(body, schoolName)}
        </p>
      </div>

      {canEdit && (
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <button
            onClick={() => save.mutate()}
            disabled={!dirty || save.isPending}
            className="rounded bg-brand-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {save.isPending ? 'Saving…' : 'Save wording'}
          </button>
          {dirty && (
            <button
              onClick={() => setBody(t.body)}
              className="rounded border border-slate-300 px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-50"
            >
              Cancel
            </button>
          )}
          {!t.is_default && !dirty && (
            <button
              onClick={() => restore.mutate()}
              disabled={restore.isPending}
              className="rounded border border-slate-300 px-3 py-1.5 text-xs text-slate-600 hover:bg-slate-50 disabled:opacity-50"
            >
              {restore.isPending ? 'Restoring…' : 'Restore original'}
            </button>
          )}
          {saved && <span className="text-xs text-money-700">Saved</span>}
          {(save.isError || toggle.isError || restore.isError) && (
            <span className="text-xs text-red-600">
              {((save.error ?? toggle.error ?? restore.error) as Error).message}
            </span>
          )}
        </div>
      )}
    </div>
  )
}

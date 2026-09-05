/**
 * The one control that puts a photograph on a record.
 *
 * Used for pupils, staff and the school logo, so a clerk learns it once. The
 * reasoning, with the argument against each choice, is in docs/PHOTOS-DESIGN.md;
 * the four that shape this file:
 *
 *  * The upload starts the moment a file is chosen: no "confirm" step. The
 *    objection is obvious: pick the wrong file and the wrong face is on the
 *    record. What makes it safe is that the path is DERIVED from the pupil, so
 *    re-uploading overwrites in place. A wrong photo is one click from being the
 *    right one, and there is no half-finished state to clean up. A confirm step
 *    would add a state machine whose failure modes are worse than the mistake it
 *    prevents.
 *  * No cropping tool. A downscale keeps the aspect ratio and the display
 *    centre-crops, which is right for a face and wrong for nothing that matters.
 *    A crop UI is a week of work and a permanent source of bugs.
 *  * `accept="image/*"` with no `capture` attribute. On a phone that offers the
 *    clerk both the camera and the gallery; forcing `capture` would take the
 *    gallery away, and photographing an existing print is common.
 *  * The local preview appears before the upload finishes, so the clerk sees the
 *    face they chose immediately even on a slow school connection.
 */
import { useEffect, useRef, useState } from 'react'
import { Avatar } from './Avatar'
import { MAX_UPLOAD_BYTES, PhotoError, signPath } from '@/lib/photos'

type Busy = 'idle' | 'uploading' | 'removing'

export function PhotoUpload({
  name, path, url: givenUrl, onUpload, onRemove, onChanged, disabled,
  size = 'xl', square = true, label = 'photograph', compact = false,
}: {
  /** For the initials fallback and the alt text. */
  name: string | null | undefined
  /** The stored path, or null. */
  path: string | null
  /**
   * A signed URL for `path`, when the caller already has one.
   *
   * Pass this on any screen showing MANY of these controls. A class photo
   * sheet of forty, say, where one batched `signPaths` beats forty individual
   * ones. Leave it undefined and the control signs its own, which is right for
   * a single profile page.
   */
  url?: string | null
  onUpload: (file: File) => Promise<string>
  onRemove: () => Promise<void>
  /** Called after either succeeds, so the page can refetch the record. */
  onChanged?: () => void
  disabled?: boolean
  size?: 'sm' | 'md' | 'lg' | 'xl'
  square?: boolean
  /** Appears in the buttons and messages: "photograph", "logo". */
  label?: string
  /** Face over a single small button, for a grid. */
  compact?: boolean
}) {
  const file = useRef<HTMLInputElement>(null)
  const [busy, setBusy] = useState<Busy>('idle')
  const [err, setErr] = useState<string | null>(null)
  const [ownUrl, setOwnUrl] = useState<string | null>(null)
  // A local object URL, shown while the bytes are still going up.
  const [preview, setPreview] = useState<string | null>(null)

  const signsItself = givenUrl === undefined

  // Mint a display URL for the stored path. Signed URLs expire, so this is done
  // per page view and never cached in the database.
  useEffect(() => {
    if (!signsItself) return
    let live = true
    setOwnUrl(null)
    if (!path) return
    signPath(path).then((u) => { if (live) setOwnUrl(u) })
    return () => { live = false }
  }, [path, signsItself])

  const url = signsItself ? ownUrl : givenUrl ?? null

  // An object URL held past its use leaks the whole decoded image.
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview) }, [preview])

  const pick = async (chosen: File | undefined) => {
    if (!chosen) return
    setErr(null)
    // Checked here as well as in the upload helpers so the clerk is told before
    // a 3 MB file crawls up a school DSL line and is then refused.
    if (chosen.size > MAX_UPLOAD_BYTES * 8) {
      setErr(`That file is ${(chosen.size / 1024 / 1024).toFixed(1)} MB, which is far too large for a ${label}. `
             + 'Please choose a normal photo from a phone or camera.')
      return
    }
    const local = URL.createObjectURL(chosen)
    setPreview((old) => { if (old) URL.revokeObjectURL(old); return local })
    setBusy('uploading')
    try {
      await onUpload(chosen)
      onChanged?.()
    } catch (e) {
      setErr(e instanceof PhotoError || e instanceof Error ? e.message : `The ${label} could not be saved.`)
      setPreview((old) => { if (old) URL.revokeObjectURL(old); return null })
    } finally {
      setBusy('idle')
      // Cleared so choosing the SAME file again still fires onChange, which is
      // what a clerk does after a failed upload.
      if (file.current) file.current.value = ''
    }
  }

  const remove = async () => {
    setErr(null)
    setBusy('removing')
    try {
      await onRemove()
      setPreview((old) => { if (old) URL.revokeObjectURL(old); return null })
      setOwnUrl(null)
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : `The ${label} could not be removed.`)
    } finally {
      setBusy('idle')
    }
  }

  const shown = preview ?? url
  const has = !!(path || preview)
  const working = busy !== 'idle'

  const picker = (
    <input
      ref={file} type="file" accept="image/jpeg,image/png,image/webp" className="hidden"
      onChange={(e) => pick(e.target.files?.[0])}
    />
  )

  if (compact) {
    // For a grid of a whole class: the face IS the button, so photographing
    // forty pupils is forty taps rather than forty page loads.
    return (
      <div className="flex flex-col items-center gap-1">
        {picker}
        <button
          type="button" disabled={disabled || working}
          onClick={() => file.current?.click()}
          title={has ? `Change ${label}` : `Add ${label}`}
          className="relative rounded-md ring-offset-2 focus:outline-none focus:ring-2 focus:ring-brand-500 disabled:cursor-default"
        >
          <Avatar name={name} url={shown} size={size} square={square} />
          {working && (
            <span className="absolute inset-0 flex items-center justify-center rounded-md bg-white/70 text-[10px] font-medium text-slate-700">
              {busy === 'uploading' ? '…' : '×'}
            </span>
          )}
          {!has && !disabled && !working && (
            <span className="absolute -bottom-1 -right-1 flex h-5 w-5 items-center justify-center rounded-full bg-brand-600 text-xs font-bold leading-none text-white print:hidden">
              +
            </span>
          )}
        </button>
        {has && !disabled && (
          <button
            type="button" onClick={remove} disabled={working}
            className="text-[10px] text-slate-400 hover:text-red-600 print:hidden"
          >
            remove
          </button>
        )}
        {err && <p className="max-w-[7rem] text-center text-[10px] leading-tight text-red-600">{err}</p>}
      </div>
    )
  }

  return (
    <div className="flex items-start gap-4">
      <div className="relative">
        <Avatar name={name} url={shown} size={size} square={square} />
        {working && (
          <span className="absolute inset-0 flex items-center justify-center rounded-md bg-white/70 text-[11px] font-medium text-slate-700">
            {busy === 'uploading' ? 'Saving…' : 'Removing…'}
          </span>
        )}
      </div>

      <div className="min-w-0 space-y-2">
        {picker}
        <div className="flex flex-wrap gap-2">
          <button
            type="button" disabled={disabled || working}
            onClick={() => file.current?.click()}
            className="rounded border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60"
          >
            {has ? `Change ${label}` : `Add ${label}`}
          </button>
          {has && (
            <button
              type="button" disabled={disabled || working} onClick={remove}
              className="rounded border border-slate-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50 disabled:opacity-60"
            >
              Remove
            </button>
          )}
        </div>
        {err
          ? <p className="max-w-xs text-xs text-red-600">{err}</p>
          : (
            <p className="max-w-xs text-xs text-slate-500">
              JPEG, PNG or WebP. Taken on a phone is fine. It is resized automatically.
            </p>
          )}
        {disabled && !err && (
          <p className="text-xs text-slate-500">Only the office can change a {label}.</p>
        )}
      </div>
    </div>
  )
}

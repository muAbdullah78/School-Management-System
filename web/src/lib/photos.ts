/**
 * Photographs and the school logo.
 *
 * The reasoning behind every decision here, with the argument against it, is in
 * docs/PHOTOS-DESIGN.md. What matters at this layer:
 *
 *  * The bucket is PRIVATE, so nothing can be shown without a signed URL. A
 *    public bucket would mean anyone holding the link sees a child's photograph,
 *    forever, with no login, including after they have left the school.
 *  * A signed URL EXPIRES, so it is never stored. The database holds a path; the
 *    URL is minted for the page that is about to display it.
 *  * The path is never chosen here. `fn_set_student_photo` derives it from the
 *    school and the pupil and ignores what it was handed, so "upload into
 *    another school's folder" is not expressible from the client at all.
 *  * The browser downscale is a COURTESY, not a control. It is what keeps a 4 MB
 *    phone photograph from becoming 4 MB of storage. The real enforcement is the
 *    bucket's own size and mime limits, because a crafted request skips this
 *    code entirely.
 */
import { requireSupabase } from './supabase'

export const PHOTO_BUCKET = 'school-files'

/** How long a minted URL lasts. Long enough to render and print a class list,
 *  short enough that a leaked link is not a lasting exposure. */
const SIGNED_URL_TTL_SECONDS = 60 * 30

/** Longest edge after downscaling. 512 is generous for a face on a screen and
 *  on a printed ID card, and turns a 4 MB phone photo into roughly 60 KB. */
const MAX_EDGE = 512
const JPEG_QUALITY = 0.82

/** What the bucket itself will accept. Kept in step with migration 0057: if
 *  these disagree, the browser lets a file through and the server rejects it,
 *  which reads to the user as "the upload is broken". */
export const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp']
export const MAX_UPLOAD_BYTES = 2 * 1024 * 1024

export class PhotoError extends Error {}

/**
 * Shrink an image in the browser before it is uploaded.
 *
 * Returns a JPEG blob. Transparency is lost, which is correct for a photograph
 * and wrong for a logo, so the logo path skips this (see uploadLogo).
 */
export async function downscale(file: File, maxEdge = MAX_EDGE): Promise<Blob> {
  if (!ACCEPTED_TYPES.includes(file.type)) {
    throw new PhotoError(
      `${file.type || 'That file'} is not an image the school can use. Use a JPEG, PNG or WebP.`)
  }

  const bitmap = await loadBitmap(file)
  try {
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
    const w = Math.max(1, Math.round(bitmap.width * scale))
    const h = Math.max(1, Math.round(bitmap.height * scale))

    const canvas = document.createElement('canvas')
    canvas.width = w
    canvas.height = h
    const ctx = canvas.getContext('2d')
    if (!ctx) throw new PhotoError('This browser cannot resize images. Try a different browser.')
    // White behind the image: a transparent PNG flattened onto nothing becomes
    // black, and a black square is not a photograph of a child.
    ctx.fillStyle = '#ffffff'
    ctx.fillRect(0, 0, w, h)
    ctx.drawImage(bitmap, 0, 0, w, h)

    const blob = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/jpeg', JPEG_QUALITY))
    if (!blob) throw new PhotoError('The image could not be processed. Try another file.')
    return blob
  } finally {
    // createImageBitmap holds decoded pixels; a class of 40 uploads leaks
    // hundreds of megabytes without this.
    if ('close' in bitmap && typeof bitmap.close === 'function') bitmap.close()
  }
}

async function loadBitmap(file: File): Promise<ImageBitmap | HTMLImageElement> {
  if (typeof createImageBitmap === 'function') {
    try {
      return await createImageBitmap(file)
    } catch {
      // Safari has historically refused some files here; fall through.
    }
  }
  return await new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file)
    const img = new Image()
    img.onload = () => { URL.revokeObjectURL(url); resolve(img) }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new PhotoError('That file is not an image the browser can read.'))
    }
    img.src = url
  })
}

/** Upload a pupil's photograph and record its path. Returns the stored path. */
export async function uploadStudentPhoto(studentId: string, file: File): Promise<string> {
  return uploadVia(file, 'fn_set_student_photo', { p_student_id: studentId })
}

/** Upload a staff photograph, for the ID card. */
export async function uploadStaffPhoto(staffId: string, file: File): Promise<string> {
  return uploadVia(file, 'fn_set_staff_photo', { p_staff_id: staffId })
}

/**
 * Upload the school logo.
 *
 * Not downscaled to JPEG: a logo is usually a PNG with a transparent
 * background, and flattening it onto white puts a white box on every printed
 * challan and result card. It is size-checked instead, and refused if too big
 * rather than silently mangled.
 */
export async function uploadLogo(file: File, previousPath?: string | null): Promise<string> {
  if (!ACCEPTED_TYPES.includes(file.type)) {
    throw new PhotoError('Use a PNG, JPEG or WebP for the logo. A PNG with a transparent background prints best.')
  }
  if (file.size > MAX_UPLOAD_BYTES) {
    throw new PhotoError(
      `That logo is ${(file.size / 1024 / 1024).toFixed(1)} MB. The limit is 2 MB: please use a smaller file.`)
  }
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_set_school_logo', { p_path: file.name })
  if (error) throw new PhotoError(error.message)
  const path = data as string
  const up = await sb.storage.from(PHOTO_BUCKET).upload(path, file, {
    upsert: true, contentType: file.type,
  })
  if (up.error) throw new PhotoError(up.error.message)
  // The logo keeps the uploader's extension, so replacing a PNG with a JPEG
  // writes a NEW object and leaves the old one behind. The one path in this
  // layer where an upsert does not overwrite. Pupil and staff photographs are
  // always stored as .jpg and so cannot drift this way.
  if (previousPath && previousPath !== path) {
    await sb.storage.from(PHOTO_BUCKET).remove([previousPath])
  }
  return path
}

/**
 * The shared upload path.
 *
 * The RPC runs FIRST and returns the path it decided on, then the bytes go to
 * that path. That order matters: it means the client never invents a path, and a
 * caller who is not allowed to change this photograph is refused before any
 * bytes are transferred.
 */
async function uploadVia(
  file: File, rpc: string, args: Record<string, unknown>,
): Promise<string> {
  const sb = requireSupabase()
  const blob = await downscale(file)
  if (blob.size > MAX_UPLOAD_BYTES) {
    // Should be unreachable after a 512px downscale; kept because "should be"
    // is not a guarantee and the server-side rejection message is opaque.
    throw new PhotoError('The image is still too large after resizing. Try a smaller photo.')
  }

  const { data, error } = await sb.rpc(rpc, { ...args, p_path: 'upload.jpg' })
  if (error) throw new PhotoError(error.message)
  const path = data as string
  if (!path) throw new PhotoError('The server did not return a path for this photograph.')

  const up = await sb.storage.from(PHOTO_BUCKET).upload(path, blob, {
    upsert: true, contentType: 'image/jpeg',
  })
  if (up.error) throw new PhotoError(up.error.message)
  return path
}

/** Remove a pupil's photograph: clear the column, then delete the object. */
export async function removeStudentPhoto(studentId: string, path: string | null): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_student_photo', {
    p_student_id: studentId, p_path: null,
  })
  if (error) throw new PhotoError(error.message)
  // Column first, object second. If the delete fails the pupil already shows no
  // photograph, which is the state the user asked for; an orphaned object costs
  // 60 KB. The other order would leave a path pointing at nothing, which renders
  // as a broken image and looks like data loss.
  if (path) await sb.storage.from(PHOTO_BUCKET).remove([path])
}

export async function removeStaffPhoto(staffId: string, path: string | null): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_staff_photo', { p_staff_id: staffId, p_path: null })
  if (error) throw new PhotoError(error.message)
  if (path) await sb.storage.from(PHOTO_BUCKET).remove([path])
}

export async function removeLogo(path: string | null): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_school_logo', { p_path: null })
  if (error) throw new PhotoError(error.message)
  if (path) await sb.storage.from(PHOTO_BUCKET).remove([path])
}

/**
 * Mint display URLs for many paths in ONE request.
 *
 * A class list of forty pupils signed one at a time is forty round trips, which
 * is the whole objection to a private bucket. `createSignedUrls` answers it.
 *
 * Nulls and blanks are filtered out first. A pupil with no photograph is a
 * normal state, and asking Supabase to sign an empty path returns an error that
 * would take the whole class list down with it.
 */
export async function signPaths(paths: (string | null | undefined)[]): Promise<Map<string, string>> {
  const wanted = [...new Set(paths.filter((p): p is string => !!p && p.trim() !== ''))]
  const out = new Map<string, string>()
  if (wanted.length === 0) return out

  const sb = requireSupabase()
  const { data, error } = await sb.storage
    .from(PHOTO_BUCKET)
    .createSignedUrls(wanted, SIGNED_URL_TTL_SECONDS)
  // A failure here must not take the page down: photographs are decoration on
  // top of the records, and a class list without faces is still a class list.
  if (error || !data) return out
  for (const row of data) {
    if (row.signedUrl && row.path) out.set(row.path, row.signedUrl)
  }
  return out
}

/** One path. Returns null rather than throwing, for the same reason. */
export async function signPath(path: string | null | undefined): Promise<string | null> {
  if (!path) return null
  const m = await signPaths([path])
  return m.get(path) ?? null
}

/** Initials for the fallback avatar: "Muhammad Ali Khan" → "MK". */
export function initials(name: string | null | undefined): string {
  const parts = (name ?? '').trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return '?'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[parts.length - 1][0]).toUpperCase()
}

/** A stable colour per person, so the same child is always the same colour and
 *  a class list is scannable even with no photographs at all. */
export function avatarTone(seed: string | null | undefined): string {
  const TONES = [
    'bg-brand-100 text-brand-800', 'bg-money-100 text-money-800',
    'bg-amber-100 text-amber-800', 'bg-violet-100 text-violet-800',
    'bg-sky-100 text-sky-800', 'bg-rose-100 text-rose-800',
  ]
  const s = seed ?? ''
  let h = 0
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) % 100000
  return TONES[h % TONES.length]
}

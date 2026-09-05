/**
 * A face, or initials.
 *
 * A missing photograph is a NORMAL state, not an error: most schools will not
 * have photographed every pupil on day one, and a broken-image icon in a class
 * list reads as a fault in the software. So the fallback is deliberate design
 * rather than an afterthought: stable initials on a stable colour, so the same
 * child is always the same colour and a photo-less class list is still scannable.
 *
 * The signed URL is passed IN rather than fetched here. One `signPaths` call
 * covers a whole class; a component that signed its own URL would make a class
 * list of forty do forty round trips, which is the main objection to keeping the
 * bucket private.
 */
import { useState } from 'react'
import { initials, avatarTone } from '@/lib/photos'

const SIZES = {
  sm: 'h-8 w-8 text-[11px]',
  md: 'h-10 w-10 text-xs',
  lg: 'h-16 w-16 text-base',
  xl: 'h-28 w-28 text-2xl',
} as const

export function Avatar({
  name, url, size = 'md', className = '', square = false,
}: {
  name: string | null | undefined
  /** A signed URL, or null when there is no photograph. */
  url?: string | null
  size?: keyof typeof SIZES
  className?: string
  /** ID cards and result cards want a passport-style square, not a circle. */
  square?: boolean
}) {
  // A signed URL can expire while the page is open, and a 400 from storage
  // renders as a broken-image glyph. Falling back to initials on error means the
  // worst case looks intentional.
  const [failed, setFailed] = useState(false)
  const shape = square ? 'rounded-md' : 'rounded-full'
  const base = `${SIZES[size]} ${shape} shrink-0 overflow-hidden ${className}`

  if (url && !failed) {
    return (
      <img
        src={url}
        alt={name ? `Photograph of ${name}` : 'Photograph'}
        onError={() => setFailed(true)}
        className={`${base} object-cover bg-slate-100`}
      />
    )
  }
  return (
    <span
      aria-label={name ? `${name}: no photograph on record` : 'No photograph'}
      title={name ?? undefined}
      className={`${base} ${avatarTone(name)} flex items-center justify-center font-semibold select-none`}
    >
      {initials(name)}
    </span>
  )
}

/**
 * The school logo, or the school's name.
 *
 * A blank box on a printed challan that a parent takes to the bank looks like a
 * defect in the school, not in the software, so a school with no logo gets its
 * name set in type instead, which is a perfectly respectable letterhead.
 */
export function SchoolMark({
  name, url, className = '',
}: {
  name: string | null | undefined
  url?: string | null
  className?: string
}) {
  const [failed, setFailed] = useState(false)
  if (url && !failed) {
    return (
      <img
        src={url}
        alt={name ? `${name} logo` : 'School logo'}
        onError={() => setFailed(true)}
        className={`max-h-16 max-w-[9rem] object-contain ${className}`}
      />
    )
  }
  return (
    <span className={`text-lg font-bold leading-tight tracking-tight text-slate-800 ${className}`}>
      {name ?? ''}
    </span>
  )
}

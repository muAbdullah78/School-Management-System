import { useEffect, useRef } from 'react'
import { cleanPin } from './checkinKit'

/**
 * A six digit PIN typed on big keys.
 *
 * Not an <input>. On a phone an input brings up the system keyboard, which
 * covers half the screen, pushes the page about, and on some Android keyboards
 * opens on letters. These keys stay put, are thumb sized, and `touch-action:
 * manipulation` stops a quick double tap zooming the page instead of typing
 * two digits. A physical keyboard still works, for the office computer.
 *
 * The sixth digit submits by itself: one less thing to press with a bag in the
 * other hand at the gate.
 */
export function PinPad({
  value, onChange, onComplete, disabled = false, label = 'Six digit PIN',
}: {
  value: string
  onChange: (v: string) => void
  onComplete: (pin: string) => void
  disabled?: boolean
  label?: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  const latest = useRef(value)
  latest.current = value

  function press(d: string) {
    if (disabled) return
    const next = cleanPin(latest.current + d)
    if (next === latest.current) return
    onChange(next)
    if (next.length === 6) onComplete(next)
  }
  function back() { if (!disabled) onChange(latest.current.slice(0, -1)) }
  function clear() { if (!disabled) onChange('') }

  // Typing on a keyboard, and pasting a PIN from a message.
  useEffect(() => {
    const el = ref.current
    if (!el) return
    function onKey(e: KeyboardEvent) {
      if (/^\d$/.test(e.key)) { e.preventDefault(); press(e.key) }
      else if (e.key === 'Backspace') { e.preventDefault(); back() }
      else if (e.key === 'Escape') { e.preventDefault(); clear() }
    }
    function onPaste(e: ClipboardEvent) {
      const t = cleanPin(e.clipboardData?.getData('text') ?? '')
      if (!t) return
      e.preventDefault()
      onChange(t)
      if (t.length === 6) onComplete(t)
    }
    el.addEventListener('keydown', onKey)
    el.addEventListener('paste', onPaste)
    return () => { el.removeEventListener('keydown', onKey); el.removeEventListener('paste', onPaste) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [disabled])

  const key = 'flex h-14 items-center justify-center rounded-2xl text-2xl font-semibold tabular-nums '
    + 'transition active:scale-95 disabled:opacity-40 focus:outline-none focus-visible:ring-2 focus-visible:ring-brand-500'

  return (
    <div ref={ref} tabIndex={0} aria-label={label} className="select-none outline-none"
      style={{ touchAction: 'manipulation' }}>
      {/* The six places, filled as they are typed. */}
      <div className="flex justify-center gap-2" aria-live="polite" aria-label={`${value.length} of 6 digits entered`}>
        {Array.from({ length: 6 }, (_, i) => {
          const d = value[i]
          return (
            <span key={i}
              className={`flex h-12 w-10 items-center justify-center rounded-xl text-2xl font-semibold tabular-nums ring-1 sm:w-11 ${
                d ? 'bg-white text-slate-900 ring-brand-300' : i === value.length ? 'bg-brand-50 ring-2 ring-brand-400' : 'bg-slate-50 ring-slate-200'}`}>
              {d ?? ''}
            </span>
          )
        })}
      </div>

      <div className="mx-auto mt-4 grid max-w-[18rem] grid-cols-3 gap-2">
        {['1', '2', '3', '4', '5', '6', '7', '8', '9'].map((d) => (
          <button key={d} type="button" disabled={disabled} onClick={() => press(d)}
            className={`${key} bg-slate-100 text-slate-900 hover:bg-slate-200`}
            style={{ touchAction: 'manipulation' }}>{d}</button>
        ))}
        <button type="button" disabled={disabled || !value} onClick={clear}
          className={`${key} text-sm font-medium text-slate-500 hover:bg-slate-100`}
          style={{ touchAction: 'manipulation' }}>Clear</button>
        <button type="button" disabled={disabled} onClick={() => press('0')}
          className={`${key} bg-slate-100 text-slate-900 hover:bg-slate-200`}
          style={{ touchAction: 'manipulation' }}>0</button>
        <button type="button" disabled={disabled || !value} onClick={back} aria-label="Delete the last digit"
          className={`${key} text-slate-600 hover:bg-slate-100`}
          style={{ touchAction: 'manipulation' }}>
          <svg viewBox="0 0 24 24" className="h-6 w-6" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
            <path d="M21 5H9l-6 7 6 7h12a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1Z" /><path d="m17 9-6 6M11 9l6 6" />
          </svg>
        </button>
      </div>
    </div>
  )
}

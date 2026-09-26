import { useSearchParams } from 'react-router-dom'

/**
 * A tab that lives in the address bar, as ?tab=<key>.
 *
 * Settings and Reports kept their tab in component state, so a link to either
 * could only ever open its FIRST tab. The dashboard's "Day book" shortcut
 * landed on Fee Collection, and a warning that needed Year Rollover could only
 * tell the reader which tab to go and find. With the tab in the URL a link
 * opens the right screen, a reload stays on it, and a colleague sent the link
 * sees the same thing.
 *
 * The history entry is REPLACED, not pushed: a tab is not a page, and ten tab
 * clicks should not take ten presses of Back to leave the screen. An unknown
 * or missing key falls back to the first tab rather than rendering nothing.
 */
export function useUrlTab<K extends string>(keys: readonly K[], fallback: K) {
  const [params, setParams] = useSearchParams()
  const raw = params.get('tab')
  const picked = raw != null && (keys as readonly string[]).includes(raw)
  const value: K = picked ? (raw as K) : fallback
  /** `explicit` writes the tab even when it is the first one. A phone shows the
   *  list of screens when no tab is named, so choosing the first screen from
   *  that list has to name it, or the list would simply come back. */
  function set(next: K, opts?: { explicit?: boolean; push?: boolean }) {
    const p = new URLSearchParams(params)
    if (next === fallback && !opts?.explicit) p.delete('tab')
    else p.set('tab', next)
    // `push` is the phone opening a screen from the list: a real history
    // entry, so the phone's own Back button returns to the list instead of
    // leaving Settings altogether. The state marks it for the in-page Back.
    if (opts?.push) setParams(p, { state: { fromIndex: true } })
    else setParams(p, { replace: true })
  }
  /** Back to no tab named: the list of screens on a phone, the first screen on
   *  a wide one. */
  function clear() {
    const p = new URLSearchParams(params)
    p.delete('tab')
    setParams(p, { replace: true })
  }
  return [value, set, { picked, clear }] as const
}

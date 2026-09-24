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
  const value: K = raw != null && (keys as readonly string[]).includes(raw) ? (raw as K) : fallback
  function set(next: K) {
    const p = new URLSearchParams(params)
    if (next === fallback) p.delete('tab')
    else p.set('tab', next)
    setParams(p, { replace: true })
  }
  return [value, set] as const
}

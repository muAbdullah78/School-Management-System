/** Read-through offline cache for reference data the attendance screen needs.
 *
 *  The offline queue (offlineQueue.ts) covers *writing* attendance while offline.
 *  This covers *reading*. It stashes the last successful result of a fetch and,
 *  if a later fetch fails because the device is offline, serves the stashed copy.
 *  That lets a teacher open the app with no connection and still see the class
 *  list and roster (not just keep marking a page that was already open). */

import { isNetworkError } from './offlineQueue'

const PREFIX = 'sm.cache.'

export function cacheSet(key: string, value: unknown): void {
  try { localStorage.setItem(PREFIX + key, JSON.stringify(value)) } catch { /* quota / private mode */ }
}

export function cacheGet<T>(key: string): T | null {
  try {
    const s = localStorage.getItem(PREFIX + key)
    return s ? (JSON.parse(s) as T) : null
  } catch {
    return null
  }
}

/** Fetch fresh and cache it; if the fetch fails *because we're offline*, fall
 *  back to the last cached value. Real errors (permissions, bad input) still
 *  throw. */
export async function offlineFirst<T>(key: string, fetcher: () => Promise<T>): Promise<T> {
  try {
    const value = await fetcher()
    cacheSet(key, value)
    return value
  } catch (e) {
    if (isNetworkError(e)) {
      const cached = cacheGet<T>(key)
      if (cached != null) return cached
    }
    throw e
  }
}

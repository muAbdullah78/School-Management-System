// Which device this is, what it runs on, and which version of the offline
// protocol it speaks.
import type { Platform } from './server'
import { isNativeApp } from '@/native/native'

/**
 * The version of this app as far as working offline is concerned. The server
 * answers every hello with the oldest version it still accepts
 * (fn__min_app_version), and an older app stops sending rather than send a
 * command the server would read differently. Raise it with a release that
 * changes what a command means.
 */
export const APP_VERSION = '1.0.0'

const DEVICE_KEY = 'sm.device_id'
let sessionOnlyId: string | null = null

function uuid(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  // Older WebViews: a version 4 UUID from the same random source.
  const b = new Uint8Array(16)
  crypto.getRandomValues(b)
  b[6] = (b[6] & 0x0f) | 0x40
  b[8] = (b[8] & 0x3f) | 0x80
  const h = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

export function isUuid(s: unknown): s is string {
  return typeof s === 'string'
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s)
}

/** A new id for a command, an admission or anything else made on this device. */
export function newId(): string { return uuid() }

/**
 * One id per browser profile or installed app, kept for as long as its storage
 * is. Clearing the browser's data makes a new device as far as the school can
 * see, which is right: the old one's offline work went with it.
 */
export function deviceId(): string {
  try {
    const known = localStorage.getItem(DEVICE_KEY)
    if (isUuid(known)) return known
    const made = uuid()
    localStorage.setItem(DEVICE_KEY, made)
    return made
  } catch {
    // Storage switched off (a private window): this tab is its own device.
    sessionOnlyId ??= uuid()
    return sessionOnlyId
  }
}

export function platform(): Platform {
  if (typeof window === 'undefined') return 'web'
  if (isNativeApp()) return 'android'
  const w = window as unknown as { __TAURI__?: unknown; __TAURI_INTERNALS__?: unknown }
  if (w.__TAURI__ !== undefined || w.__TAURI_INTERNALS__ !== undefined) return 'windows'
  return 'web'
}

/** -1, 0 or 1, comparing dotted version numbers part by part ("1.10.0" > "1.9.3"). */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map((x) => parseInt(x, 10) || 0)
  const pb = b.split('.').map((x) => parseInt(x, 10) || 0)
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d !== 0) return d < 0 ? -1 : 1
  }
  return 0
}

// The server half of working offline (migration 0157), as typed calls.
//
// The device never writes rows while offline. It keeps COMMANDS, each with an
// id it made itself, and hands them in through applyCommands when it connects.
// The server runs each one through the same functions the screens use online
// and remembers its id, so sending the same command twice applies it once.
//
// Everything here is a thin call. The outbox, the clock and the retry rules
// live beside this file, not in it.
import { requireSupabase } from '../lib/supabase'

/** The command types the server understands, release 1. */
export type CommandType =
  | 'attendance.day'
  | 'attendance.subject'
  | 'marks.exam'
  | 'marks.test'
  | 'fees.payment'
  | 'fees.family_payment'
  | 'expenses.record'
  | 'students.admit'

/** The version of the command format this app writes. */
export const COMMAND_VERSION = 1

/** Most commands the server takes in one call. */
export const MAX_BATCH = 25

export interface Command {
  /** Made on the device (crypto.randomUUID), kept until the server answers. */
  id: string
  type: CommandType
  /** When the work was done, on the server's clock (device clock plus offset). */
  occurred_at: string
  payload: Record<string, unknown>
  v: number
}

export interface ReceiptBlock { first_no: number; last_no: number }

export interface Hello {
  server_time: string
  status: string
  role: string | null
  /** False for a locked school, a switched-off device, or a role that only reads. */
  can_write: boolean
  /** The school switched this device off. Hand in what is waiting, then clear it. */
  revoked: boolean
  /** Work may be done offline until this moment. Null when it may not. */
  lease_until: string | null
  /** Receipt numbers this device may print offline, lowest first. */
  receipt_blocks: ReceiptBlock[]
  command_version: number
  min_app_version: string
}

export type Platform = 'web' | 'android' | 'windows'

export async function syncHello(
  deviceId: string, platform: Platform, appVersion: string | null, receiptNext: number | null,
): Promise<Hello> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_sync_hello', {
    p_device_id: deviceId,
    p_platform: platform,
    p_app_version: appVersion,
    p_receipt_next: receiptNext,
  })
  if (error) throw new Error(error.message)
  return data as Hello
}

/**
 * applied:  done, and kept, so sending it again returns this same answer.
 * rejected: refused for good and kept for the owner to see. Move it to Needs
 *           attention; it can be sent again only as a new command.
 * deferred: not kept. Hold on to it and send it again later. Nothing after it
 *           in the same batch was looked at.
 */
export type CommandStatus = 'applied' | 'rejected' | 'deferred'

export interface CommandResult {
  id: string | null
  status: CommandStatus
  /** What the server function returned, for applied commands. */
  result?: Record<string, unknown> | null
  /** receipt_renumbered: the printed number was used or not ours; see result.printed_receipt_no. */
  flags?: string[]
  /**
   * Why it was refused or has to wait: bad_command, bad_date, device_revoked,
   * clock_ahead, too_old, too_large, outside_lease, not_permitted, duplicate,
   * possible_duplicate, refused (rejected); device_unknown, server_behind,
   * school_locked, busy (deferred).
   */
  code?: string | null
  error?: string | null
  /** This id had already been handed in; the answer is the one given then. */
  repeat?: boolean
}

export interface ApplyAnswer { server_time: string; results: CommandResult[] }

export async function applyCommands(deviceId: string, commands: Command[]): Promise<ApplyAnswer> {
  if (commands.length > MAX_BATCH) throw new Error(`Send at most ${MAX_BATCH} entries at a time.`)
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_offline_apply', {
    p_device_id: deviceId,
    p_commands: commands,
  })
  if (error) throw new Error(error.message)
  return data as ApplyAnswer
}

export interface DeviceBlock extends ReceiptBlock {
  issued_at: string
  closed_at: string | null
  closed_reason: 'used' | 'device_revoked' | null
  /** Payments recorded with a number from this block. */
  used: number
}

export interface SchoolDevice {
  device_id: string
  user_id: string
  name: string | null
  role: string | null
  platform: string
  app_version: string | null
  first_seen: string
  last_seen: string
  lease_until: string | null
  revoked_at: string | null
  revoked_by: string | null
  revoke_reason: string | null
  receipt_blocks: DeviceBlock[]
  /** Refused commands from this device nobody has looked at yet. */
  refused: number
}

/** Every staff device for the owner and principal; your own for anyone else. */
export async function schoolDevices(): Promise<SchoolDevice[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_school_devices')
  if (error) throw new Error(error.message)
  return (data ?? []) as SchoolDevice[]
}

/** Switch a device off for good: no more offline work, its receipt numbers closed. */
export async function revokeDevice(
  deviceId: string, userId: string, reason: string | null,
): Promise<{ revoked: boolean; already: boolean }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_revoke_device', {
    p_device_id: deviceId,
    p_user_id: userId,
    p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as { revoked: boolean; already: boolean }
}

export interface OfflineReviewItem {
  id: string
  type: string
  status: 'applied' | 'rejected'
  occurred_at: string | null
  received_at: string
  user_id: string
  name: string | null
  device_id: string
  error: string | null
  error_code: string | null
  flags: string[]
  payload: Record<string, unknown> | null
  result: Record<string, unknown> | null
  reviewed_at: string | null
  reviewed_by: string | null
}

/** Refused commands, and applied ones the owner should see (a renumbered receipt). */
export async function offlineReview(includeReviewed = false): Promise<OfflineReviewItem[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_offline_review', { p_include_reviewed: includeReviewed })
  if (error) throw new Error(error.message)
  return (data ?? []) as OfflineReviewItem[]
}

export async function offlineDismiss(commandId: string): Promise<boolean> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_offline_dismiss', { p_command_id: commandId })
  if (error) throw new Error(error.message)
  return Boolean((data as { dismissed?: boolean } | null)?.dismissed)
}

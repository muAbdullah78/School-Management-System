/** Payment methods — values must match the `payment_method` enum in the DB. */
export const PAYMENT_METHODS: { value: string; label: string }[] = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank_challan', label: 'Bank Challan' },
  { value: 'jazzcash', label: 'JazzCash' },
  { value: 'easypaisa', label: 'Easypaisa' },
  { value: 'bank_transfer', label: 'Bank Transfer' },
  { value: 'other', label: 'Other' },
]

export const INVOICE_STATUS_LABELS: Record<string, string> = {
  draft: 'Draft',
  issued: 'Issued',
  partial: 'Partial',
  paid: 'Paid',
  void: 'Void',
}

/**
 * Attendance statuses — `value` must match the `attendance_status` enum in the DB.
 * `on`/`off` are the Tailwind classes for a selected vs. unselected toggle chip;
 * `key` is the single-key keyboard shortcut for fast marking.
 */
export interface AttendanceStatusMeta {
  value: 'present' | 'absent' | 'leave' | 'late' | 'half_day'
  label: string
  short: string
  key: string
  on: string
  off: string
}
export const ATTENDANCE_STATUSES: AttendanceStatusMeta[] = [
  { value: 'present',  label: 'Present',   short: 'P',  key: 'p', on: 'bg-emerald-600 text-white ring-emerald-600', off: 'text-emerald-700 ring-emerald-200 hover:bg-emerald-50' },
  { value: 'absent',   label: 'Absent',    short: 'A',  key: 'a', on: 'bg-red-600 text-white ring-red-600',         off: 'text-red-700 ring-red-200 hover:bg-red-50' },
  { value: 'leave',    label: 'Leave',     short: 'L',  key: 'l', on: 'bg-sky-600 text-white ring-sky-600',         off: 'text-sky-700 ring-sky-200 hover:bg-sky-50' },
  { value: 'late',     label: 'Late',      short: 'Lt', key: 't', on: 'bg-amber-500 text-white ring-amber-500',     off: 'text-amber-700 ring-amber-200 hover:bg-amber-50' },
  { value: 'half_day', label: 'Half day',  short: '½',  key: 'h', on: 'bg-violet-600 text-white ring-violet-600',   off: 'text-violet-700 ring-violet-200 hover:bg-violet-50' },
]
export const ATTENDANCE_LABELS: Record<string, string> = Object.fromEntries(
  ATTENDANCE_STATUSES.map((s) => [s.value, s.label]),
)
export const ATTENDANCE_SHORT: Record<string, string> = Object.fromEntries(
  ATTENDANCE_STATUSES.map((s) => [s.value, s.short]),
)

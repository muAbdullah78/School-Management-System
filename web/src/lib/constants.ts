/** Payment methods: values must match the `payment_method` enum in the DB. */
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

/** Payment clearance state: `status` on the payments row. */
export const PAYMENT_STATUS_LABELS: Record<string, string> = {
  verified: 'Cleared',
  pending: 'Pending clearance',
  cancelled: 'Cancelled',
}

/** Suggested family-relationship labels for the admission sibling/relative link
 *  (free text is still allowed via the datalist). */
export const RELATIONS: string[] = [
  'Brother', 'Sister', 'Cousin', 'Step-brother', 'Step-sister', 'Relative',
]

/**
 * Attendance statuses: `value` must match the `attendance_status` enum in the DB.
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
  // ONE SET OF LETTERS, used by the register, the teacher's calendar and the
  // parent portal alike. Leave was "L" here while the calendars used "L" for
  // Late, so a teacher and a parent could read the same letter two ways. The
  // keyboard keys are unchanged (t is late, l is leave), because teachers who
  // mark by keyboard already know them. Brand colours, not raw Tailwind ones:
  // green is present, amber is late or half day, red absent, sky leave.
  { value: 'present',  label: 'Present',   short: 'P',  key: 'p', on: 'bg-money-600 text-white ring-money-600',  off: 'text-money-700 ring-money-200 hover:bg-money-50' },
  { value: 'absent',   label: 'Absent',    short: 'A',  key: 'a', on: 'bg-danger-600 text-white ring-danger-600', off: 'text-danger-700 ring-danger-200 hover:bg-danger-50' },
  { value: 'leave',    label: 'Leave',     short: 'Lv', key: 'l', on: 'bg-sky-600 text-white ring-sky-600',       off: 'text-sky-700 ring-sky-200 hover:bg-sky-50' },
  { value: 'late',     label: 'Late',      short: 'Lt', key: 't', on: 'bg-due-500 text-white ring-due-500',       off: 'text-due-800 ring-due-200 hover:bg-due-50' },
  { value: 'half_day', label: 'Half day',  short: '½',  key: 'h', on: 'bg-due-300 text-due-900 ring-due-300',     off: 'text-due-800 ring-due-200 hover:bg-due-50' },
]
export const ATTENDANCE_LABELS: Record<string, string> = Object.fromEntries(
  ATTENDANCE_STATUSES.map((s) => [s.value, s.label]),
)

/** Gender options: values must match the `gender` enum in the DB. */
export const GENDERS: { value: string; label: string }[] = [
  { value: 'male', label: 'Male' },
  { value: 'female', label: 'Female' },
  { value: 'other', label: 'Other' },
]

/** Discount types: values must match the `discount_type` enum in the DB. */
export const DISCOUNT_TYPES: { value: string; label: string }[] = [
  { value: 'sibling', label: 'Sibling' },
  { value: 'merit', label: 'Merit' },
  { value: 'staff_child', label: 'Staff child' },
  { value: 'hardship', label: 'Hardship' },
  { value: 'scholarship', label: 'Scholarship' },
  { value: 'other', label: 'Other' },
]
export const DISCOUNT_STATUS_LABELS: Record<string, string> = {
  pending: 'Pending', approved: 'Approved', rejected: 'Rejected', revoked: 'Revoked',
}

/** Student status: values must match the `student_status` enum in the DB. */
export const STUDENT_STATUS_LABELS: Record<string, string> = {
  active: 'Active',
  struck_off: 'Struck off',
  withdrawn: 'Withdrawn',
  graduated: 'Graduated',
}

/** Exam term types: values must match the `term_type` enum in the DB. */
export const TERM_TYPES: { value: string; label: string }[] = [
  { value: 'first', label: 'First Term' },
  { value: 'mid', label: 'Mid Term' },
  { value: 'second', label: 'Second Term' },
  { value: 'final', label: 'Final Term' },
  { value: 'pre_board', label: 'Pre-Board' },
  { value: 'other', label: 'Other' },
]

/** Certificate types: values must match the `certificate_type` enum in the DB. */
export const CERT_TYPES: { value: string; label: string }[] = [
  { value: 'leaving', label: 'Leaving Certificate' },
  { value: 'character', label: 'Character Certificate' },
  { value: 'bonafide', label: 'Bonafide Certificate' },
  { value: 'id_card', label: 'ID Card' },
  { value: 'other', label: 'Other' },
]
export const CERT_LABELS: Record<string, string> = Object.fromEntries(CERT_TYPES.map((t) => [t.value, t.label]))
export const ATTENDANCE_SHORT: Record<string, string> = Object.fromEntries(
  ATTENDANCE_STATUSES.map((s) => [s.value, s.short]),
)

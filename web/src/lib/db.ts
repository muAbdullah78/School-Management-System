import { requireSupabase } from './supabase'

// ---- Types (hand-written; kept in sync with supabase/migrations) ----
export interface SessionRow { id: string; name: string; is_current: boolean }
export interface ClassRow { id: string; name: string; level_order: number }
export interface FeeHead {
  id: string; name: string; type: string; is_recurring: boolean; active: boolean; sort_order: number
  /** Money the school HOLDS and must give back — a security deposit. It is a
   *  liability, not income, and is billed on its own challan. See
   *  docs/DEPOSITS-DESIGN.md. */
  is_refundable: boolean
}
export interface StudentRow {
  id: string; gr_no: string | null; full_name: string; father_name: string | null
}
export interface InvoiceBalance {
  invoice_id: string; period_month: string | null; status: string; due_date: string | null
  arrears_brought_forward: number; fine: number; charge: number; allocated: number
  deferred_until: string | null; defer_reason: string | null
}
export interface PaymentRow {
  id: string; amount: number; method: string; receipt_no: number | null
  created_at: string; note: string | null; reversal_of: string | null; status: string
}
export interface Defaulter {
  student_id: string; gr_no: string | null; full_name: string
  class_name: string; section_name: string | null; roll_no: string | null; balance: number
}
export interface RecordPaymentResult {
  payment_id: string; receipt_no: number; allocated: number; unallocated: number
}
export type AttendanceStatus = 'present' | 'absent' | 'leave' | 'late' | 'half_day'
export interface SectionRow { id: string; name: string; class_id: string }
export interface RosterRow {
  enrollment_id: string; student_id: string; full_name: string; father_name: string | null
  roll_no: string | null; status: AttendanceStatus | null; is_locked: boolean
}
export interface MarkResult { marked: number; skipped: number; total: number }
export interface AttendanceSummary {
  present: number; absent: number; leave: number; late: number; half_day: number
  marked_days: number; present_pct: number | null
}

function unwrap<T>(res: { data: T | null; error: { message: string } | null }): T {
  if (res.error) throw new Error(res.error.message)
  return res.data as T
}

/**
 * A write that changed nothing is an ERROR, not a success.
 *
 * Row Level Security treats the three write verbs differently, and forgetting
 * this produced a defect that reads to a school as lost work:
 *
 *   INSERT with no matching policy          -> raises
 *   UPDATE / DELETE with no matching policy -> ZERO ROWS, and no error at all
 *
 * So every direct-table write in this file used to be written as
 * `const { error } = await sb.from(x).update(patch).eq('id', id)` — and `error`
 * is null when nothing matched. Demonstrated: as a `readonly` login,
 * `update students set full_name` returned success with zero rows. The app said
 * "Saved.", the value was unchanged, and reopening the record showed the old one.
 *
 * The same silence produced a second, unrelated bug: when the create-teacher
 * Edge Function is not deployed the fallback path created a login with no
 * profile row, so the follow-up role update matched nothing, raised nothing, and
 * the app reported success on a login that could not use the app.
 *
 * So: every such statement now carries `.select('id')`, and an empty result
 * raises. Two real causes, and the message names both, because from outside they
 * are indistinguishable.
 *
 * NOT for RPCs. A SECURITY DEFINER function raises its own errors and reports
 * what it did, which is why every write that really matters — payments, marks,
 * leavings, rollovers — goes through one.
 */
async function mustWrite(
  res: { data: unknown[] | null; error: { message: string } | null },
  what: string,
): Promise<void> {
  if (res.error) throw new Error(res.error.message)
  if (!res.data || res.data.length === 0) {
    throw new Error(
      `${what} was not saved. You may not have permission to change it, `
      + 'or somebody else may have changed it first.',
    )
  }
}

// ---- Reference data ----
export async function getCurrentSession(): Promise<SessionRow | null> {
  const sb = requireSupabase()
  const { data, error } = await sb
    .from('academic_sessions')
    .select('id, name, is_current')
    .eq('is_current', true)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (error) throw new Error(error.message)
  return data
}

export async function listClasses(): Promise<ClassRow[]> {
  const sb = requireSupabase()
  return unwrap(await sb.from('classes').select('id, name, level_order').eq('active', true).order('level_order'))
}

export async function listFeeHeads(): Promise<FeeHead[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('fee_heads')
      .select('id, name, type, is_recurring, is_refundable, active, sort_order')
      .eq('active', true).order('sort_order'),
  )
}

// ---- Fee structure (amount per class per head) ----
export async function getFeeStructure(sessionId: string, classId: string): Promise<Record<string, number>> {
  const sb = requireSupabase()
  const rows = unwrap<{ fee_head_id: string; amount: number }[]>(
    await sb.from('fee_structures').select('fee_head_id, amount').eq('session_id', sessionId).eq('class_id', classId),
  )
  const map: Record<string, number> = {}
  for (const r of rows) map[r.fee_head_id] = Number(r.amount)
  return map
}

export async function upsertFeeStructure(
  sessionId: string, classId: string, feeHeadId: string, amount: number,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb
    .from('fee_structures')
    .upsert({ session_id: sessionId, class_id: classId, fee_head_id: feeHeadId, amount }, {
      onConflict: 'session_id,class_id,fee_head_id',
    })
  if (error) throw new Error(error.message)
}

// ---- Students ----
export async function searchStudents(q: string): Promise<StudentRow[]> {
  const sb = requireSupabase()
  const term = q.trim()
  if (!term) return []
  const like = `%${term.replace(/[%,()]/g, ' ')}%`
  return unwrap(
    await sb
      .from('students')
      .select('id, gr_no, full_name, father_name')
      .or(`full_name.ilike.${like},gr_no.ilike.${like}`)
      .is('deleted_at', null)
      .limit(20),
  )
}

// ---- Fees: generation, ledger, collection ----
export async function generateClassInvoices(
  sessionId: string, classId: string, periodMonth: string, dueDate: string,
): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_generate_class_invoices', {
    p_session_id: sessionId, p_class_id: classId, p_period_month: periodMonth, p_due_date: dueDate,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}

export async function getStudentBalance(studentId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('student_balance', { p_student_id: studentId })
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

export async function getStudentInvoices(studentId: string): Promise<InvoiceBalance[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb
      .from('invoice_balances')
      .select('invoice_id, period_month, status, due_date, arrears_brought_forward, fine, charge, allocated, deferred_until, defer_reason')
      .eq('student_id', studentId)
      .order('period_month', { ascending: false }),
  )
}

export async function getStudentPayments(studentId: string): Promise<PaymentRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb
      .from('payments')
      .select('id, amount, method, receipt_no, created_at, note, reversal_of, status')
      .eq('student_id', studentId)
      .order('created_at', { ascending: false }),
  )
}

export async function recordPayment(
  studentId: string, amount: number, method: string, note?: string, pending = false,
): Promise<RecordPaymentResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_payment', {
    p_student_id: studentId, p_amount: amount, p_method: method, p_note: note ?? null, p_pending: pending,
  })
  if (error) throw new Error(error.message)
  return data as RecordPaymentResult
}

export async function verifyPayment(paymentId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_verify_payment', { p_payment_id: paymentId })
  if (error) throw new Error(error.message)
}

export async function cancelPendingPayment(paymentId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_cancel_pending_payment', { p_payment_id: paymentId, p_reason: reason })
  if (error) throw new Error(error.message)
}

/** School-wide pending (un-cleared) payments, newest first — the "Pending
 *  clearances" queue for bank challans / wallet transfers awaiting verification. */
export interface PendingPaymentRow {
  id: string; amount: number; method: string; receipt_no: number | null; created_at: string
  note: string | null; student_id: string; student_name: string | null; gr_no: string | null
}
export async function listPendingPayments(): Promise<PendingPaymentRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('payments')
      .select('id, amount, method, receipt_no, created_at, note, student_id, students(full_name, gr_no)')
      .eq('status', 'pending')
      .order('created_at', { ascending: false }),
  )
  return rows.map((r) => ({
    id: r.id, amount: Number(r.amount), method: r.method,
    receipt_no: r.receipt_no == null ? null : Number(r.receipt_no),
    created_at: r.created_at, note: r.note, student_id: r.student_id,
    student_name: r.students?.full_name ?? null, gr_no: r.students?.gr_no ?? null,
  }))
}

/** Bill ONE student for ONE month on demand (single-student challan). Returns
 *  the invoice id; re-billing the same month returns the existing invoice. */
export async function billStudentMonth(
  enrollmentId: string, periodMonth: string, dueDate: string,
): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_bill_student_month', {
    p_enrollment_id: enrollmentId, p_period_month: periodMonth, p_due_date: dueDate,
  })
  if (error) throw new Error(error.message)
  return data as string
}

export async function deferInvoice(invoiceId: string, until: string | null, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_defer_invoice', { p_invoice_id: invoiceId, p_until: until, p_reason: reason })
  if (error) throw new Error(error.message)
}

export async function undoDefer(invoiceId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_undo_defer', { p_invoice_id: invoiceId })
  if (error) throw new Error(error.message)
}

export interface MonthlyFee { gross: number; discount: number; net: number }
export async function getStudentMonthlyFee(enrollmentId: string): Promise<MonthlyFee> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_student_monthly_fee', { p_enrollment_id: enrollmentId })
  if (error) throw new Error(error.message)
  const d = data as any
  return { gross: Number(d.gross), discount: Number(d.discount), net: Number(d.net) }
}

export interface MonthTestRow {
  assessment_id: string; title: string; subject_name: string | null; assessment_date: string | null
  max_marks: number; marks: number | null; is_absent: boolean
  class_avg: number | null; class_count: number; pass_mark: number; passed: boolean
}
export async function getStudentMonthTests(enrollmentId: string, monthFirst: string): Promise<MonthTestRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.rpc('fn_student_month_tests', { p_enrollment_id: enrollmentId, p_month: monthFirst }),
  )
  return (rows ?? []).map((r) => ({
    assessment_id: r.assessment_id, title: r.title, subject_name: r.subject_name,
    assessment_date: r.assessment_date, max_marks: Number(r.max_marks),
    marks: r.marks == null ? null : Number(r.marks), is_absent: !!r.is_absent,
    class_avg: r.class_avg == null ? null : Number(r.class_avg), class_count: Number(r.class_count ?? 0),
    pass_mark: Number(r.pass_mark), passed: !!r.passed,
  }))
}

/** One student's day-by-day attendance for a month ('YYYY-MM'). */
export async function getStudentMonthAttendance(
  enrollmentId: string, month: string,
): Promise<{ attendance_date: string; status: string }[]> {
  const sb = requireSupabase()
  const [y, m] = month.split('-').map(Number)
  const last = `${month}-${String(new Date(y, m, 0).getDate()).padStart(2, '0')}`
  return unwrap(
    await sb.from('attendance_daily')
      .select('attendance_date, status')
      .eq('enrollment_id', enrollmentId)
      .gte('attendance_date', `${month}-01`).lte('attendance_date', last)
      .order('attendance_date'),
  )
}

export async function reversePayment(paymentId: string, reason: string): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_reverse_payment', { p_payment_id: paymentId, p_reason: reason })
  if (error) throw new Error(error.message)
  return data as string
}

// ---- Discounts / fines / adjustments (fee engine depth) ----
export interface DiscountRow {
  id: string; enrollment_id: string; type: string; amount: number; is_percent: boolean
  reason: string | null; status: string; created_at: string
  student_name: string | null; gr_no: string | null; class_name: string | null
}
export interface CurrentEnrollment { enrollment_id: string; class_name: string; section_name: string | null }

export async function getCurrentEnrollment(studentId: string): Promise<CurrentEnrollment | null> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('enrollments')
      .select('id, classes(name), sections(name), academic_sessions!inner(is_current)')
      .eq('student_id', studentId).eq('academic_sessions.is_current', true).limit(1),
  )
  if (!rows.length) return null
  return { enrollment_id: rows[0].id, class_name: rows[0].classes?.name ?? '—', section_name: rows[0].sections?.name ?? null }
}

export async function listDiscounts(): Promise<DiscountRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('discounts')
      .select('id, enrollment_id, type, amount, is_percent, reason, status, created_at, enrollments!inner(students(full_name, gr_no), classes(name))')
      .order('created_at', { ascending: false }),
  )
  return rows.map((r) => ({
    id: r.id, enrollment_id: r.enrollment_id, type: r.type, amount: Number(r.amount),
    is_percent: r.is_percent, reason: r.reason, status: r.status, created_at: r.created_at,
    student_name: r.enrollments?.students?.full_name ?? null,
    gr_no: r.enrollments?.students?.gr_no ?? null,
    class_name: r.enrollments?.classes?.name ?? null,
  }))
}

export async function addDiscount(
  enrollmentId: string, type: string, amount: number, isPercent: boolean, reason: string,
): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_add_discount', {
    p_enrollment_id: enrollmentId, p_type: type, p_amount: amount, p_is_percent: isPercent, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  return data as string
}

/** Approved/pending discounts for one enrolment (drives the profile Fees strip). */
export async function getEnrollmentDiscounts(enrollmentId: string): Promise<DiscountRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('discounts')
      .select('id, enrollment_id, type, amount, is_percent, reason, status, created_at')
      .eq('enrollment_id', enrollmentId)
      .order('created_at', { ascending: false }),
  )
  return rows.map((r) => ({
    id: r.id, enrollment_id: r.enrollment_id, type: r.type, amount: Number(r.amount),
    is_percent: r.is_percent, reason: r.reason, status: r.status, created_at: r.created_at,
    student_name: null, gr_no: null, class_name: null,
  }))
}

export async function setDiscountStatus(discountId: string, status: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_discount_status', { p_discount_id: discountId, p_status: status })
  if (error) throw new Error(error.message)
}

export async function applyFine(invoiceId: string, amount: number, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_apply_fine', { p_invoice_id: invoiceId, p_amount: amount, p_reason: reason })
  if (error) throw new Error(error.message)
}

export async function waiveFine(invoiceId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_waive_fine', { p_invoice_id: invoiceId, p_reason: reason })
  if (error) throw new Error(error.message)
}

export async function addAdjustment(studentId: string, amount: number, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_add_adjustment', { p_student_id: studentId, p_amount: amount, p_reason: reason })
  if (error) throw new Error(error.message)
}

// ---- Fee reconciliation (expected vs collected + ghost check) ----
export interface ReconClassRow { class_name: string; expected: number; collected: number; outstanding: number }
export interface ReconStudent { gr_no: string | null; full_name: string; class_name: string }
export interface FeeReconciliation {
  expected: number; collected: number; outstanding: number
  by_class: ReconClassRow[]; uninvoiced: ReconStudent[]; ghost_suspects: ReconStudent[]
}
export async function getFeeReconciliation(sessionId: string): Promise<FeeReconciliation> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_fee_reconciliation', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
  const d = data as any
  return {
    expected: Number(d.expected), collected: Number(d.collected), outstanding: Number(d.outstanding),
    by_class: (d.by_class ?? []).map((r: any) => ({
      class_name: r.class_name, expected: Number(r.expected), collected: Number(r.collected), outstanding: Number(r.outstanding),
    })),
    uninvoiced: d.uninvoiced ?? [],
    ghost_suspects: d.ghost_suspects ?? [],
  }
}

export async function getDefaulters(sessionId: string): Promise<Defaulter[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_defaulters', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
  return (data as Defaulter[]) ?? []
}

// ---- Reports ----
export interface CollectionRow {
  id: string; created_at: string; amount: number; method: string; receipt_no: number | null
  student_name: string | null; gr_no: string | null; note: string | null; is_reversal: boolean
}
export interface ClassStrengthRow {
  class_name: string; level_order: number; section_name: string | null
  boys: number; girls: number; other: number; total: number
}

/** Verified payments in [fromDate, toDate] (inclusive dates), for the day-book /
 *  collection report. Reversals appear as negative rows. */
export async function listCollections(fromDate: string, toDate: string): Promise<CollectionRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('payments')
      .select('id, created_at, amount, method, receipt_no, note, reversal_of, students(full_name, gr_no)')
      .eq('status', 'verified')
      .gte('created_at', fromDate)
      .lte('created_at', `${toDate}T23:59:59.999`)
      .order('created_at', { ascending: true }),
  )
  return rows.map((r) => ({
    id: r.id, created_at: r.created_at, amount: Number(r.amount), method: r.method,
    receipt_no: r.receipt_no == null ? null : Number(r.receipt_no),
    student_name: r.students?.full_name ?? null, gr_no: r.students?.gr_no ?? null,
    note: r.note, is_reversal: r.reversal_of != null,
  }))
}

// ---- Monthly attendance register ----
export interface RegisterStudent {
  enrollment_id: string; full_name: string; roll_no: string | null
  marks: Record<string, string> // 'YYYY-MM-DD' → attendance status
}
export interface AttendanceRegister { dates: string[]; students: RegisterStudent[] }

/** Day-by-day attendance grid for a class (optionally one section) over a month.
 *  `month` is 'YYYY-MM'. Columns are every calendar day of that month. */
export async function getAttendanceRegister(
  sessionId: string, classId: string, sectionId: string | null, month: string,
): Promise<AttendanceRegister> {
  const sb = requireSupabase()
  const [y, m] = month.split('-').map(Number)
  const lastDay = new Date(y, m, 0).getDate()
  const first = `${month}-01`
  const last = `${month}-${String(lastDay).padStart(2, '0')}`
  const dates = Array.from({ length: lastDay }, (_, i) => `${month}-${String(i + 1).padStart(2, '0')}`)

  let rq = sb.from('enrollments')
    .select('id, roll_no, students!inner(full_name)')
    .eq('session_id', sessionId).eq('class_id', classId).eq('status', 'active')
  if (sectionId) rq = rq.eq('section_id', sectionId)
  const enr = unwrap<Record<string, any>[]>(await rq)
  const rollNum = (r: string | null) => {
    const n = parseInt((r ?? '').replace(/[^0-9]/g, ''), 10)
    return Number.isNaN(n) ? Number.MAX_SAFE_INTEGER : n
  }
  const students: RegisterStudent[] = enr
    .map((e) => ({ enrollment_id: e.id, full_name: e.students?.full_name ?? '—', roll_no: e.roll_no ?? null, marks: {} as Record<string, string> }))
    .sort((a, b) => rollNum(a.roll_no) - rollNum(b.roll_no) || a.full_name.localeCompare(b.full_name))

  if (students.length > 0) {
    const byId = new Map(students.map((s) => [s.enrollment_id, s]))
    const marks = unwrap<Record<string, any>[]>(
      await sb.from('attendance_daily')
        .select('enrollment_id, attendance_date, status')
        .in('enrollment_id', students.map((s) => s.enrollment_id))
        .gte('attendance_date', first).lte('attendance_date', last),
    )
    for (const mk of marks) {
      const s = byId.get(mk.enrollment_id)
      if (s) s.marks[mk.attendance_date] = mk.status
    }
  }
  return { dates, students }
}

/** Active-enrolment head-count per class/section with a gender split. */
export async function getClassStrength(sessionId: string): Promise<ClassStrengthRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('enrollments')
      .select('class_id, section_id, classes(name, level_order), sections(name, sort_order), students(gender)')
      .eq('session_id', sessionId).eq('status', 'active'),
  )
  const map = new Map<string, ClassStrengthRow>()
  for (const r of rows) {
    const key = `${r.class_id}|${r.section_id ?? ''}`
    let row = map.get(key)
    if (!row) {
      row = {
        class_name: r.classes?.name ?? '—', level_order: r.classes?.level_order ?? 1e9,
        section_name: r.sections?.name ?? null, boys: 0, girls: 0, other: 0, total: 0,
      }
      map.set(key, row)
    }
    const g = r.students?.gender
    if (g === 'male') row.boys++
    else if (g === 'female') row.girls++
    else row.other++
    row.total++
  }
  return [...map.values()].sort((a, b) =>
    a.level_order - b.level_order || (a.section_name ?? '').localeCompare(b.section_name ?? ''))
}

// ---- Attendance ----
export async function listSections(classId: string): Promise<SectionRow[]> {
  const sb = requireSupabase()
  if (!classId) return []
  return unwrap(
    await sb.from('sections').select('id, name, class_id').eq('class_id', classId).order('sort_order').order('name'),
  )
}

/** Roster for one section on one date. `sectionId = null` → the class's ungrouped students. */
export async function getRoster(
  sessionId: string, classId: string, sectionId: string | null, date: string,
): Promise<RosterRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_section_roster', {
    p_session_id: sessionId, p_class_id: classId, p_section_id: sectionId, p_date: date,
  })
  if (error) throw new Error(error.message)
  return (data as RosterRow[]) ?? []
}

/**
 * `reason` is recorded only against rows whose status actually CHANGED, and it
 * is what makes the corrections report readable — see getAttendanceCorrections.
 */
export async function markAttendance(
  date: string, marks: { enrollment_id: string; status: AttendanceStatus }[],
  reason?: string | null,
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_mark_attendance', {
    p_date: date, p_marks: marks, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
  return data as MarkResult
}

export async function finalizeAttendance(
  sessionId: string, classId: string, sectionId: string | null, date: string,
): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_finalize_attendance', {
    p_session_id: sessionId, p_class_id: classId, p_section_id: sectionId, p_date: date,
  })
  if (error) throw new Error(error.message)
  return Number(data)
}

export async function attendanceSummary(
  enrollmentId: string, from: string, to: string,
): Promise<AttendanceSummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_attendance_summary', {
    p_enrollment_id: enrollmentId, p_from: from, p_to: to,
  })
  if (error) throw new Error(error.message)
  return data as AttendanceSummary
}

// ---- Admissions & student profile ----
export interface AdmitInput {
  full_name: string
  father_name?: string; mother_name?: string; b_form?: string; dob?: string; gender?: string
  address?: string; phone?: string; whatsapp?: string
  /**
   * The father's (or guardian's) CNIC. This is what puts siblings in the SAME
   * family, so a single payment covers all of them — see migration 0036. It is
   * optional on purpose: a walk-in without their card must still be admitted,
   * and the sibling checkbox below covers that case.
   */
  father_cnic?: string
  admission_no?: string; admission_date?: string; notes?: string
  session_id: string; class_id: string; section_id?: string | null; roll_no?: string; gr_no?: string
  guardian?: { name: string; relation?: string; phone?: string; whatsapp?: string }
  links?: { related_student_id: string; relation?: string }[]
  admission_fee?: { charged: boolean; amount?: number | null }
}
export interface AdmitResult {
  student_id: string; enrollment_id: string; gr_no: string; roll_no: string
  family_id: string | null
  admission_fee_amount: number | null; admission_receipt_no: number | null
}

export interface StudentProfile {
  id: string; gr_no: string | null; admission_no: string | null; full_name: string
  father_name: string | null; mother_name: string | null; b_form: string | null
  dob: string | null; gender: string | null; address: string | null; phone: string | null
  whatsapp: string | null; status: string; admission_date: string | null; notes: string | null
  /** Added in 0057. A PATH inside the school-files bucket, never a URL — a
   *  signed URL expires and a persisted one becomes a broken image. */
  photo_path: string | null
  /** Added in 0054. Null for a child who is here, and null for one who left
   *  before 0054 existed — the migration deliberately did not invent dates. */
  left_on: string | null; leaving_reason: string | null
}

export interface StudentLeftRow {
  left_on: string; student_id: string; student_name: string
  gr_no: string | null; father_name: string | null; phone: string | null
  class_name: string | null; section_name: string | null
  status: string; reason: string | null
  admitted_on: string | null; months_here: number | null; balance: number
}

export interface StudentStatusResult {
  student_name: string; status: string; left_on: string | null; class_name: string
}
export interface EnrollmentInfo {
  enrollment_id: string; session_id: string; session_name: string
  session_starts: string | null; session_ends: string | null
  class_name: string; section_name: string | null; roll_no: string | null; status: string
}
export interface GuardianRow {
  id: string; name: string; relation: string | null; phone: string | null; whatsapp: string | null; is_primary: boolean
}

export async function admitStudent(input: AdmitInput): Promise<AdmitResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_admit_student', { p: input })
  if (error) throw new Error(error.message)
  return data as AdmitResult
}

/**
 * Move a student into a sibling's family, merging the two.
 *
 * The repair path for the 0036 bug. No automatic rule catches every case — a
 * father with two phone numbers, a name spelled two ways, or anything admitted
 * before 0036 existed — so the counter needs a way to fix it without SQL.
 * Returns the surviving family id.
 */
export async function studentJoinFamily(studentId: string, siblingStudentId: string): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_student_join_family', {
    p_student_id: studentId, p_sibling_student_id: siblingStudentId,
  })
  if (error) throw new Error(error.message)
  return data as string
}

/**
 * Sweep the whole school for siblings sitting in separate families and merge
 * them: explicit sibling links first, then same father name + same phone.
 *
 * Mainly for after a CSV import, which has no father-CNIC column and so leaves
 * every imported sibling apart. Returns how many families were merged.
 */
export async function repairFamilies(): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_repair_families')
  if (error) throw new Error(error.message)
  return (data as number) ?? 0
}

// ---- Bulk import (onboarding a paper register) ----
export type ImportRowStatus = 'created' | 'ok' | 'skipped' | 'error'
export interface ImportRowResult {
  row: number; status: ImportRowStatus; message: string | null; name: string
  gr_no?: string | null; amount?: number | null
}
export interface ImportResult {
  dry_run: boolean; total: number; created: number; skipped: number; errors: number
  rows: ImportRowResult[]
}

/** Validate (dry run) or import a batch of students into a session. Rows use
 *  canonical keys (see lib/importStudents); class/section are matched by name. */
export async function importStudents(
  sessionId: string, rows: Record<string, string>[], dryRun: boolean,
): Promise<ImportResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_import_students', {
    p_session: sessionId, p_rows: rows, p_dry_run: dryRun,
  })
  if (error) throw new Error(error.message)
  return data as ImportResult
}

/** Validate (dry run) or import each student's opening fee balance into a
 *  session. Rows use canonical keys (see lib/importBalances); the student is
 *  matched by GR No / Admission No / Name. */
export async function importOpeningBalances(
  sessionId: string, rows: Record<string, string>[], dryRun: boolean,
): Promise<ImportResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_import_opening_balances', {
    p_session: sessionId, p_rows: rows, p_dry_run: dryRun,
  })
  if (error) throw new Error(error.message)
  return data as ImportResult
}

// ---- Academic-year rollover ----
export interface RolloverRuleInput {
  from_class_id: string; action: 'promote' | 'retain' | 'graduate'; to_class_id: string | null
}
export interface RolloverRowResult {
  student_id: string; name: string; gr_no: string | null
  from_class: string | null; to_class: string | null; action: string
  roll_no: string | null; balance: number; message: string | null
}
export interface RolloverResult {
  commit: boolean; from_session: string; to_session: string
  promoted: number; retained: number; graduated: number; unmapped: number; skipped: number; total: number
  rows: RolloverRowResult[]
}
export interface RolloverUndoResult { undone: number; note: string; graduated_total: number }

/** Preview (commit=false, no writes) or apply (commit=true) a year-end rollover
 *  from one session to another using per-class rules. */
export async function runRollover(
  fromSession: string, toSession: string, rules: RolloverRuleInput[], commit: boolean,
): Promise<RolloverResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_rollover', {
    p_from: fromSession, p_to: toSession, p_rules: rules, p_commit: commit,
  })
  if (error) throw new Error(error.message)
  return data as RolloverResult
}

/** Reverse the promotions/retentions of a rollover into a session (only allowed
 *  while that session has no attendance/fees/exams yet). */
export async function undoRollover(toSession: string): Promise<RolloverUndoResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_rollover_undo', { p_to: toSession })
  if (error) throw new Error(error.message)
  return data as RolloverUndoResult
}

/** Validate (dry run) or import a batch of staff records. Rows use canonical
 *  keys (see lib/importStaff). */
export async function importStaff(
  rows: Record<string, string>[], dryRun: boolean,
): Promise<ImportResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_import_staff', { p_rows: rows, p_dry_run: dryRun })
  if (error) throw new Error(error.message)
  return data as ImportResult
}

/**
 * A short list of students for a picker. Capped at 50 BY DESIGN — it feeds
 * type-ahead boxes, not the roster.
 *
 * For the roster use listStudentPage(), which pages properly and reports the
 * real total. This function's cap was the roster's bug: an 800-student school
 * saw fifty names and was never told the rest existed.
 */
export async function listStudents(term: string): Promise<StudentRow[]> {
  const sb = requireSupabase()
  const t = term.trim()
  let q = sb.from('students').select('id, gr_no, full_name, father_name').is('deleted_at', null)
  if (t) { const like = `%${t.replace(/[%,()]/g, ' ')}%`; q = q.or(`full_name.ilike.${like},gr_no.ilike.${like}`) }
  return unwrap(await q.order('full_name').limit(50))
}

export interface StudentListRow {
  student_id: string
  full_name: string
  gr_no: string | null
  admission_no: string | null
  father_name: string | null
  gender: string | null
  phone: string | null
  status: string
  class_name: string | null
  section_name: string | null
  roll_no: string | null
  family_id: string | null
  /** Everything this student owes. Computed set-based in SQL and asserted equal
   *  to student_balance() — see supabase/tests/student_list.sql. */
  balance: number
}

export interface StudentListPage { rows: StudentListRow[]; total: number }

/** One page of the roster, with class, section, roll and balance, and the real
 *  total so the UI can say "showing 50 of 812" instead of quietly truncating. */
export async function listStudentPage(opts: {
  term?: string
  classId?: string | null
  sectionId?: string | null
  includeInactive?: boolean
  limit?: number
  offset?: number
}): Promise<StudentListPage> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_student_list', {
    p_term: opts.term?.trim() || null,
    p_class_id: opts.classId || null,
    p_section_id: opts.sectionId || null,
    p_include_inactive: opts.includeInactive ?? false,
    p_limit: opts.limit ?? 50,
    p_offset: opts.offset ?? 0,
  })
  if (error) throw new Error(error.message)
  const raw = (data ?? []) as Record<string, unknown>[]
  return {
    // total_count is repeated on every row (one aggregate, cross-joined), so an
    // empty page legitimately means a total of zero.
    total: raw.length > 0 ? Number(raw[0].total_count ?? 0) : 0,
    rows: raw.map((r) => ({
      ...(r as unknown as StudentListRow),
      balance: Number(r.balance ?? 0),
    })),
  }
}

/** Detect likely siblings: other (non-deleted) students with the same father's
 *  name. A pragmatic family view without a schema-level family link. */
export interface SiblingRow extends StudentRow { family_id: string | null }

export async function getSiblings(studentId: string): Promise<SiblingRow[]> {
  const sb = requireSupabase()
  const me = unwrap<{ father_name: string | null }>(
    await sb.from('students').select('father_name').eq('id', studentId).single(),
  )
  const father = (me.father_name ?? '').trim()
  if (!father) return []
  // family_id comes back so the profile can say whether these children actually
  // bill together. Sharing a father's name and sharing a FAMILY are different
  // things, and conflating them is exactly the bug 0036 fixed.
  return unwrap(
    await sb.from('students')
      .select('id, gr_no, full_name, father_name, family_id')
      .neq('id', studentId).ilike('father_name', father).is('deleted_at', null)
      .order('full_name').limit(20),
  )
}

// ---- Explicit family links (sibling / relative) ----
export interface LinkedStudent {
  link_id: string; student_id: string; full_name: string; gr_no: string | null
  relation: string | null; class_name: string | null
  /** The linked student's family. Compare with your own: equal means their fees
   *  collect together, different means the link is only a label. */
  family_id: string | null
}

/** Explicit family links for a student, queried in both directions (one row per
 *  pair). class_name is the linked student's current-session class, if any. */
export async function getStudentLinks(studentId: string): Promise<LinkedStudent[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('student_links')
      .select('id, relation, student_id, related_student_id, a:students!student_links_student_id_fkey(full_name, gr_no, family_id), b:students!student_links_related_student_id_fkey(full_name, gr_no, family_id)')
      .or(`student_id.eq.${studentId},related_student_id.eq.${studentId}`),
  )
  const out: LinkedStudent[] = rows.map((r) => {
    const isA = r.student_id === studentId
    const otherId = isA ? r.related_student_id : r.student_id
    const other = isA ? r.b : r.a
    return {
      link_id: r.id, student_id: otherId, full_name: other?.full_name ?? '—',
      gr_no: other?.gr_no ?? null, relation: r.relation ?? null, class_name: null,
      family_id: other?.family_id ?? null,
    }
  })
  // attach current class (best-effort)
  if (out.length) {
    const enr = unwrap<Record<string, any>[]>(
      await sb.from('enrollments')
        .select('student_id, classes(name), academic_sessions!inner(is_current)')
        .in('student_id', out.map((o) => o.student_id))
        .eq('academic_sessions.is_current', true),
    )
    const byStudent = new Map(enr.map((e) => [e.student_id, e.classes?.name ?? null]))
    for (const o of out) o.class_name = byStudent.get(o.student_id) ?? null
  }
  return out
}

export async function linkStudents(a: string, b: string, relation: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_link_students', { p_a: a, p_b: b, p_relation: relation })
  if (error) throw new Error(error.message)
}

export async function removeStudentLink(linkId: string): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('student_links').delete().eq('id', linkId).select('id'),
    'That family link')
}

/** Search students for the admission family-link picker: match name / GR / roll,
 *  and return the current-session class + roll so the operator can disambiguate. */
export interface LinkSearchRow {
  id: string; full_name: string; gr_no: string | null; father_name: string | null
  class_name: string | null; section_name: string | null; roll_no: string | null
}
export async function searchStudentsForLink(q: string): Promise<LinkSearchRow[]> {
  const sb = requireSupabase()
  const term = q.trim()
  if (term.length < 1) return []
  const like = `%${term.replace(/[%,()]/g, ' ')}%`
  const map = new Map<string, LinkSearchRow>()

  // Name / GR on the students base table (reliable base-column filters).
  const byName = unwrap<Record<string, any>[]>(
    await sb.from('students')
      .select('id, full_name, gr_no, father_name')
      .or(`full_name.ilike.${like},gr_no.ilike.${like}`)
      .is('deleted_at', null).limit(15),
  )
  for (const s of byName) {
    map.set(s.id, {
      id: s.id, full_name: s.full_name, gr_no: s.gr_no ?? null, father_name: s.father_name ?? null,
      class_name: null, section_name: null, roll_no: null,
    })
  }

  // Roll number on the current-session enrolment.
  const byRoll = unwrap<Record<string, any>[]>(
    await sb.from('enrollments')
      .select('roll_no, students!inner(id, full_name, gr_no, father_name, deleted_at), classes(name), sections(name), academic_sessions!inner(is_current)')
      .eq('academic_sessions.is_current', true).ilike('roll_no', like).limit(15),
  )
  for (const r of byRoll) {
    if (!r.students || r.students.deleted_at) continue
    map.set(r.students.id, {
      id: r.students.id, full_name: r.students.full_name, gr_no: r.students.gr_no ?? null,
      father_name: r.students.father_name ?? null, class_name: r.classes?.name ?? null,
      section_name: r.sections?.name ?? null, roll_no: r.roll_no ?? null,
    })
  }

  // Enrich the name/GR hits with their current class + roll.
  const need = [...map.values()].filter((v) => v.class_name === null).map((v) => v.id)
  if (need.length) {
    const enr = unwrap<Record<string, any>[]>(
      await sb.from('enrollments')
        .select('roll_no, student_id, classes(name), sections(name), academic_sessions!inner(is_current)')
        .in('student_id', need).eq('academic_sessions.is_current', true),
    )
    const byStudent = new Map(enr.map((e) => [e.student_id, e]))
    for (const v of map.values()) {
      const e = byStudent.get(v.id)
      if (e) { v.class_name = e.classes?.name ?? null; v.section_name = e.sections?.name ?? null; v.roll_no = v.roll_no ?? e.roll_no ?? null }
    }
  }
  return [...map.values()].slice(0, 15)
}

export async function getStudent(studentId: string): Promise<StudentProfile> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('students')
      .select('id, gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender, address, phone, whatsapp, status, admission_date, notes, left_on, leaving_reason, photo_path')
      .eq('id', studentId).single(),
  )
}

export async function updateStudent(studentId: string, patch: Partial<StudentProfile>): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('students').update(patch).eq('id', studentId).select('id'),
    'The change to this pupil')
}

/** Record a child leaving, or coming back.
 *
 *  `leftOn` is new in 0054. Before it there was no date anywhere: the only
 *  trace of a leaving was free text appended to students.notes, so a school
 *  could not answer "when did Bilal leave". */
export async function setStudentStatus(
  studentId: string, status: string, reason?: string, leftOn?: string,
): Promise<StudentStatusResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_set_student_status', {
    p_student_id: studentId, p_status: status, p_reason: reason ?? null,
    p_left_on: leftOn ?? null,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    student_name: r.student_name ?? '',
    status: r.status ?? status,
    left_on: r.left_on ?? null,
    class_name: r.class_name ?? '—',
  }
}

/** Children who have left, with what they left owing.
 *
 *  Without this, left_on would be one more column written and never shown —
 *  the bug class documented in migration 0047. Office roles only: it carries
 *  arrears. */
export async function getStudentsLeft(from: string | null, to: string | null): Promise<StudentLeftRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.rpc('fn_students_left', { p_from: from || null, p_to: to || null }))
  return (rows ?? []).map((r) => ({
    left_on: r.left_on,
    student_id: r.student_id,
    student_name: r.student_name,
    gr_no: r.gr_no ?? null,
    father_name: r.father_name ?? null,
    phone: r.phone ?? null,
    class_name: r.class_name ?? null,
    section_name: r.section_name ?? null,
    status: r.status,
    reason: r.reason ?? null,
    admitted_on: r.admitted_on ?? null,
    months_here: r.months_here === null || r.months_here === undefined ? null : Number(r.months_here),
    balance: Number(r.balance ?? 0),
  }))
}

export async function getStudentEnrollments(studentId: string): Promise<EnrollmentInfo[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('enrollments')
      .select('id, session_id, roll_no, status, academic_sessions(name, starts_on, ends_on), classes(name), sections(name)')
      .eq('student_id', studentId)
      .order('created_at', { ascending: false }),
  )
  return rows.map((r) => ({
    enrollment_id: r.id,
    session_id: r.session_id,
    session_name: r.academic_sessions?.name ?? '—',
    session_starts: r.academic_sessions?.starts_on ?? null,
    session_ends: r.academic_sessions?.ends_on ?? null,
    class_name: r.classes?.name ?? '—',
    section_name: r.sections?.name ?? null,
    roll_no: r.roll_no,
    status: r.status,
  }))
}

export async function getGuardians(studentId: string): Promise<GuardianRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('guardians')
      .select('id, name, relation, phone, whatsapp, is_primary')
      .eq('student_id', studentId)
      .order('is_primary', { ascending: false }),
  )
}

// ---- Exams ----
export interface ExamTerm {
  id: string; name: string; term_type: string; starts_on: string | null; ends_on: string | null
  result_withheld_for_defaulters: boolean
}
export interface SubjectRow {
  id: string; name: string; class_id: string | null; sort_order: number
  /** null = every pupil in the class takes it. A value = only pupils whose
   *  enrolment stream matches. See docs/EXAM-COMPUTATION-DESIGN.md. */
  stream: string | null
  /** This subject has a practical component, which is what lets a paper carry
   *  practical marks at all. */
  is_practical: boolean
}
export interface ExamSubjectRow {
  id: string; subject_id: string; subject_name: string; max_marks: number; pass_marks: number
  practical_max: number
  exam_date: string | null; paper_time: string | null
  subject_stream: string | null; subject_is_practical: boolean
}
export interface ClassRosterRow {
  enrollment_id: string; student_id: string; full_name: string; father_name: string | null
  gr_no: string | null; roll_no: string | null; section_name: string | null
}
export interface MarksheetRow {
  enrollment_id: string; student_id: string; full_name: string; roll_no: string | null
  section_name: string | null; marks: number | null; is_absent: boolean; is_locked: boolean; max_marks: number
  /** Absent on an assessment marksheet, which has no practical concept. */
  practical_marks?: number | null
  practical_max?: number
}
export interface ResultCardRow {
  id: string; enrollment_id: string; student_id: string; full_name: string; gr_no: string | null
  roll_no: string | null; total_marks: number | null; total_max: number | null
  percentage: number | null; grade: string | null; position: number | null
  attendance_pct: number | null; version: number; frozen: ResultCardFrozen
  /** Set by fn_publish_results. Non-null means parents can see this card in the
   *  portal. Null means it exists but is withheld. */
  published_at: string | null
}
export interface ResultCardFrozen {
  subjects: {
    subject: string; max: number; practical_max: number; pass: number
    marks: number | null; practical: number | null
    obtained: number | null; out_of: number
    is_absent: boolean
    /** false = no mark row exists. NOT the same as a mark of zero, and the whole
     *  reason a pupil nobody had marked used to print as having failed. */
    marked: boolean
    passed: boolean | null
    grade: string | null
  }[]
  total_marks: number; total_max: number; percentage: number | null; grade: string | null
  position: number | null; attendance_pct: number | null; withheld: boolean; balance: number
  /** Present on cards generated by 0058 onward. Older frozen snapshots have
   *  none of these, so every reader must tolerate undefined — a reprint of last
   *  term's card must not break because this term's card gained fields. */
  exam_percentage?: number | null
  assessment_percentage?: number | null
  assessment_weight_pct?: number
  stream?: string | null
  bise_reg_no?: string | null
  failed_subjects?: number
  result?: 'PASS' | 'FAIL' | 'PENDING'
  pass_percent?: number
  provisional?: boolean
  unmarked_subjects?: number
  generated_at?: string
  version?: number
}

/** One thing standing between a class and its result cards. */
export interface ResultBlocker {
  problem: 'no papers' | 'pupils without a stream' | 'marks not entered' | string
  detail: string
  affected: number
}
export interface GenerateResult {
  generated: number
  provisional: boolean
  missing_marks: number
}
export interface ClassStreamRow {
  enrollment_id: string; student_id: string; full_name: string; father_name: string | null
  gr_no: string | null; roll_no: string | null; section_name: string | null
  stream: string | null; bise_reg_no: string | null
}

export async function listExamTerms(sessionId: string): Promise<ExamTerm[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('exam_terms')
      .select('id, name, term_type, starts_on, ends_on, result_withheld_for_defaulters')
      .eq('session_id', sessionId).order('starts_on', { ascending: true, nullsFirst: true }),
  )
}

export async function createExamTerm(
  sessionId: string, name: string, termType: string, startsOn?: string, endsOn?: string,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('exam_terms').insert({
    session_id: sessionId, name, term_type: termType, starts_on: startsOn || null, ends_on: endsOn || null,
  })
  if (error) throw new Error(error.message)
}

export async function listSubjects(classId: string): Promise<SubjectRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('subjects')
      .select('id, name, class_id, sort_order, stream, is_practical')
      .eq('class_id', classId).order('sort_order').order('name'),
  )
  return (rows ?? []).map((r) => ({
    id: r.id, name: r.name, class_id: r.class_id ?? null,
    sort_order: Number(r.sort_order ?? 0),
    stream: r.stream ?? null,
    is_practical: !!r.is_practical,
  }))
}

/** Set a subject's stream and whether it has a practical.
 *
 *  An RPC rather than a direct update because turning the practical flag OFF
 *  while papers still carry practical marks would leave those marks unreachable
 *  and silently out of every total — the function refuses that. */
export async function setSubjectDetails(
  subjectId: string, stream: string | null, isPractical: boolean,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_subject_details', {
    p_subject_id: subjectId, p_stream: stream, p_is_practical: isPractical,
  })
  if (error) throw new Error(error.message)
}

export async function createSubject(name: string, classId: string, sortOrder = 0): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('subjects').insert({ name, class_id: classId, sort_order: sortOrder })
  if (error) throw new Error(error.message)
}

export async function listExamSubjects(termId: string, classId: string): Promise<ExamSubjectRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('exam_subjects')
      .select('id, subject_id, max_marks, pass_marks, practical_max, exam_date, paper_time, subjects(name, sort_order, stream, is_practical)')
      .eq('exam_term_id', termId).eq('class_id', classId),
  )
  return rows
    .map((r) => ({
      id: r.id, subject_id: r.subject_id, subject_name: r.subjects?.name ?? '—',
      max_marks: Number(r.max_marks), pass_marks: Number(r.pass_marks),
      practical_max: Number(r.practical_max ?? 0),
      exam_date: r.exam_date ?? null, paper_time: r.paper_time ?? null,
      subject_stream: r.subjects?.stream ?? null,
      subject_is_practical: !!r.subjects?.is_practical,
      _sort: r.subjects?.sort_order ?? 0,
    }))
    .sort((a, b) => a._sort - b._sort || a.subject_name.localeCompare(b.subject_name))
    .map(({ _sort, ...rest }) => rest)
}

/**
 * Set up one paper.
 *
 * An RPC rather than a direct upsert. The upsert it replaced could not check
 * anything: it accepted a pass mark higher than the paper's total, a paper
 * against a locked term, and — once practicals existed — practical marks on a
 * subject that has no practical, which is how a practical mark ends up
 * somewhere nobody looks.
 */
export async function upsertExamSubject(
  termId: string, classId: string, subjectId: string, maxMarks: number, passMarks: number,
  practicalMax = 0, examDate?: string | null, paperTime?: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_upsert_exam_subject', {
    p_exam_term_id: termId, p_class_id: classId, p_subject_id: subjectId,
    p_max_marks: maxMarks, p_pass_marks: passMarks, p_practical_max: practicalMax,
    p_exam_date: examDate || null, p_paper_time: paperTime || null,
  })
  if (error) throw new Error(error.message)
}

/** Active roster for a class in a session (for admit cards / roll-number slips),
 *  ordered by section then numeric roll. */
export async function listClassRoster(sessionId: string, classId: string): Promise<ClassRosterRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('enrollments')
      .select('id, student_id, roll_no, students!inner(full_name, father_name, gr_no), sections(name, sort_order)')
      .eq('session_id', sessionId).eq('class_id', classId).eq('status', 'active'),
  )
  const rollNum = (r: string | null) => {
    const n = parseInt((r ?? '').replace(/[^0-9]/g, ''), 10)
    return Number.isNaN(n) ? Number.MAX_SAFE_INTEGER : n
  }
  return rows
    .map((r) => ({
      enrollment_id: r.id, student_id: r.student_id,
      full_name: r.students?.full_name ?? '—', father_name: r.students?.father_name ?? null,
      gr_no: r.students?.gr_no ?? null, roll_no: r.roll_no ?? null,
      section_name: r.sections?.name ?? null, _sort: r.sections?.sort_order ?? 0,
    }))
    .sort((a, b) => a._sort - b._sort || rollNum(a.roll_no) - rollNum(b.roll_no) || a.full_name.localeCompare(b.full_name))
    .map(({ _sort, ...rest }) => rest)
}

export async function removeExamSubject(id: string): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('exam_subjects').delete().eq('id', id).select('id'),
    'Removing that paper')
}

export async function getMarksheet(examSubjectId: string): Promise<MarksheetRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_exam_marksheet', { p_exam_subject_id: examSubjectId })
  if (error) throw new Error(error.message)
  return (data as MarksheetRow[]) ?? []
}

/**
 * `reason` lands only on marks that actually CHANGED. Entering a mark for the
 * first time is not a correction and needs no reason.
 */
export async function enterMarks(
  examSubjectId: string,
  marks: {
    enrollment_id: string; marks: number | null; is_absent: boolean
    /** Omitted for a subject with no practical. Validated server-side against
     *  exam_subjects.practical_max, not against the theory paper's maximum. */
    practical_marks?: number | null
  }[],
  reason?: string | null,
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enter_marks', {
    p_exam_subject_id: examSubjectId, p_marks: marks, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
  return data as MarkResult
}

// ---- Assessments (class tests) ----
export interface AssessmentRow {
  id: string; title: string; assessment_date: string | null; max_marks: number
  section_id: string | null; section_name: string | null
  subject_id: string | null; subject_name: string | null; is_locked: boolean
}

export async function listAssessments(sessionId: string, classId: string): Promise<AssessmentRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('assessments')
      .select('id, title, assessment_date, max_marks, is_locked, section_id, subject_id, sections(name), subjects(name)')
      .eq('session_id', sessionId).eq('class_id', classId)
      .order('assessment_date', { ascending: false, nullsFirst: false }).order('created_at', { ascending: false }),
  )
  return rows.map((r) => ({
    id: r.id, title: r.title, assessment_date: r.assessment_date, max_marks: Number(r.max_marks),
    section_id: r.section_id, section_name: r.sections?.name ?? null,
    subject_id: r.subject_id, subject_name: r.subjects?.name ?? null, is_locked: r.is_locked,
  }))
}

export async function createAssessment(input: {
  sessionId: string; classId: string; sectionId?: string | null; subjectId?: string | null
  title: string; assessmentDate?: string | null; maxMarks: number
}): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('assessments').insert({
    session_id: input.sessionId, class_id: input.classId,
    section_id: input.sectionId || null, subject_id: input.subjectId || null,
    title: input.title, assessment_date: input.assessmentDate || null, max_marks: input.maxMarks,
  }).select('id').single()
  if (error) throw new Error(error.message)
  return (data as { id: string }).id
}

export async function getAssessmentMarksheet(assessmentId: string): Promise<MarksheetRow[]> {
  const sb = requireSupabase()
  return unwrap(await sb.rpc('fn_assessment_marksheet', { p_assessment_id: assessmentId }))
}

export async function enterAssessmentMarks(
  assessmentId: string, marks: { enrollment_id: string; marks: number | null; is_absent: boolean }[],
  reason?: string | null,
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enter_assessment_marks', {
    p_assessment_id: assessmentId, p_marks: marks, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
  return data as MarkResult
}

export async function lockAssessment(assessmentId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_lock_assessment', { p_assessment_id: assessmentId })
  if (error) throw new Error(error.message)
}

/**
 * What is stopping this class's result cards?
 *
 * Read BEFORE offering the Generate button, so a school sees "Chemistry is
 * missing for 12 pupils" on the screen rather than as an exception after
 * clicking. The generator checks the same rules again itself — this is the
 * courtesy, not the enforcement.
 */
export async function getResultReadiness(
  termId: string, classId: string,
): Promise<ResultBlocker[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.rpc('fn_result_readiness', { p_exam_term_id: termId, p_class_id: classId }))
  return (rows ?? []).map((r) => ({
    problem: r.problem, detail: r.detail, affected: Number(r.affected ?? 0),
  }))
}

/**
 * Generate the class's result cards.
 *
 * `allowIncomplete` is a deliberate act, not a retry. Without it the generator
 * refuses while any pupil has an unmarked paper, because the alternative —
 * which is what it used to do — is printing a child nobody had marked as having
 * failed. With it, the affected cards are stamped provisional and their
 * denominators exclude what is missing.
 */
export async function generateResultCards(
  termId: string, classId: string, allowIncomplete = false,
): Promise<GenerateResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_generate_result_cards', {
    p_exam_term_id: termId, p_class_id: classId, p_allow_incomplete: allowIncomplete,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    generated: Number(r.generated ?? 0),
    provisional: !!r.provisional,
    missing_marks: Number(r.missing_marks ?? 0),
  }
}

/** The class list a school works down when setting streams, and the list it
 *  fills board forms from. */
export async function getClassStreams(
  classId: string, sessionId?: string | null,
): Promise<ClassStreamRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.rpc('fn_class_streams', { p_class_id: classId, p_session_id: sessionId ?? null }))
  return (rows ?? []).map((r) => ({
    enrollment_id: r.enrollment_id, student_id: r.student_id, full_name: r.full_name,
    father_name: r.father_name ?? null, gr_no: r.gr_no ?? null, roll_no: r.roll_no ?? null,
    section_name: r.section_name ?? null,
    stream: r.stream ?? null, bise_reg_no: r.bise_reg_no ?? null,
  }))
}

export async function setEnrollmentStream(
  enrollmentId: string, stream: string | null, biseRegNo: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_enrollment_stream', {
    p_enrollment_id: enrollmentId, p_stream: stream, p_bise_reg_no: biseRegNo,
  })
  if (error) throw new Error(error.message)
}

/** Latest-version result card per enrollment for a class in a term. */
export async function listResultCards(termId: string, classId: string): Promise<ResultCardRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('result_cards')
      .select('id, enrollment_id, student_id, total_marks, total_max, percentage, grade, position, attendance_pct, version, frozen, published_at, students(full_name, gr_no), enrollments!inner(class_id, roll_no)')
      .eq('exam_term_id', termId)
      .eq('enrollments.class_id', classId)
      .order('version', { ascending: false }),
  )
  const seen = new Set<string>()
  const out: ResultCardRow[] = []
  for (const r of rows) {
    if (seen.has(r.enrollment_id)) continue // rows ordered version desc → first is latest
    seen.add(r.enrollment_id)
    out.push({
      id: r.id, enrollment_id: r.enrollment_id, student_id: r.student_id,
      full_name: r.students?.full_name ?? '—', gr_no: r.students?.gr_no ?? null,
      roll_no: r.enrollments?.roll_no ?? null,
      total_marks: r.total_marks, total_max: r.total_max, percentage: r.percentage,
      grade: r.grade, position: r.position, attendance_pct: r.attendance_pct,
      version: r.version, frozen: r.frozen as ResultCardFrozen,
      published_at: r.published_at ?? null,
    })
  }
  return out.sort((a, b) => (a.position ?? 1e9) - (b.position ?? 1e9))
}

// ---- Settings / school setup ----
export interface SchoolSettings {
  name: string; name_short: string | null; address: string | null; phone: string | null
  email: string | null; principal_name: string | null; grade_scale: string; pass_percent: number
  gr_prefix: string | null; receipt_prefix: string | null; current_session_id: string | null
  geofence_enabled: boolean; geo_lat: number | null; geo_lng: number | null; geo_radius_m: number
  /** The school day, for staff lateness. With `day_starts_at` unset NOTHING is
   *  ever late — a default start time would mark a whole staff room late on the
   *  day the school upgraded. */
  day_starts_at: string | null; day_ends_at: string | null; late_grace_minutes: number
  /** A storage PATH, never a URL — see docs/PHOTOS-DESIGN.md. Read-only here;
   *  written only by fn_set_school_logo, which derives the path itself. */
  logo_path: string | null
}
/** Everything a settings form is allowed to write. `logo_path` is deliberately
 *  absent: a direct update could store a path this school does not own, and the
 *  CHECK constraint would then reject the whole save with an opaque message. */
export type SchoolSettingsPatch = Omit<SchoolSettings, 'logo_path'>
export interface SessionFull {
  id: string; name: string; starts_on: string | null; ends_on: string | null
  is_current: boolean; is_closed: boolean
}
export interface ClassFull { id: string; name: string; level_order: number; active: boolean }
export interface ProfileRow { id: string; full_name: string | null; role: string; active: boolean; staff_id: string | null }

/** The school this login belongs to. RLS keys off it; so do writes below. */
export async function mySchoolId(): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('current_school_id')
  if (error) throw new Error(error.message)
  if (!data) throw new Error('This login is not attached to a school.')
  return data as string
}

export async function getSchoolSettings(): Promise<SchoolSettings | null> {
  const sb = requireSupabase()
  // No id filter: `school_settings` used to be a single row keyed id = 1, and is
  // now one row per school. RLS already narrows this to the caller's school.
  const { data, error } = await sb.from('school_settings')
    .select('name, name_short, address, phone, email, principal_name, grade_scale, pass_percent, gr_prefix, receipt_prefix, current_session_id, geofence_enabled, geo_lat, geo_lng, geo_radius_m, day_starts_at, day_ends_at, late_grace_minutes, logo_path')
    .limit(1).maybeSingle()
  if (error) throw new Error(error.message)
  return data
}

/**
 * The school logo path on its own, for the printed documents.
 *
 * A separate, tiny read so a challan or a result card does not pull the whole
 * settings row (including the geofence coordinates) just to draw a letterhead.
 * Returns null rather than throwing: a print that fails because the logo could
 * not be read would be a worse bug than a print with no logo.
 */
export async function getSchoolLogoPath(): Promise<string | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('school_settings')
    .select('logo_path').limit(1).maybeSingle()
  if (error) return null
  return (data?.logo_path as string | null) ?? null
}

export async function updateSchoolSettings(patch: Partial<SchoolSettingsPatch>): Promise<void> {
  const sb = requireSupabase()
  // An UPDATE, not an upsert: the settings row is created with the school, so
  // there is nothing to insert — and an upsert here could only ever write a row
  // RLS would reject anyway.
  await mustWrite(
    await sb.from('school_settings').update(patch)
      .eq('school_id', await mySchoolId()).select('school_id'),
    'The school profile')
}

export async function listSessions(): Promise<SessionFull[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('academic_sessions').select('id, name, starts_on, ends_on, is_current, is_closed')
      .order('starts_on', { ascending: false, nullsFirst: false }),
  )
}

export async function createSession(name: string, startsOn?: string, endsOn?: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('academic_sessions').insert({ name, starts_on: startsOn || null, ends_on: endsOn || null })
  if (error) throw new Error(error.message)
}

export async function setCurrentSession(sessionId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_current_session', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
}

/**
 * First-run setup for a brand-new school: the academic session, the class
 * ladder, and one section per class — the minimum needed before a student can
 * be admitted.
 *
 * Done as one call so a half-finished wizard cannot leave a school with a
 * session but no classes, which looks identical to "the app is broken".
 */
export async function setupSchool(input: {
  schoolName: string
  sessionName: string
  startsOn?: string
  endsOn?: string
  classNames: string[]
  sectionsPerClass: string[]
}): Promise<void> {
  const sb = requireSupabase()

  await updateSchoolSettings({ name: input.schoolName.trim() })

  const { data: session, error: sErr } = await sb.from('academic_sessions')
    .insert({
      name: input.sessionName.trim(),
      starts_on: input.startsOn || null,
      ends_on: input.endsOn || null,
    })
    .select('id').single()
  if (sErr) throw new Error(sErr.message)

  await setCurrentSession(session.id as string)

  const classes = input.classNames.map((n) => n.trim()).filter(Boolean)
  if (classes.length) {
    const { data: made, error: cErr } = await sb.from('classes')
      .insert(classes.map((name, i) => ({ name, level_order: i + 1 })))
      .select('id, name')
    if (cErr) throw new Error(cErr.message)

    const sections = (input.sectionsPerClass ?? []).map((s) => s.trim()).filter(Boolean)
    if (sections.length && made?.length) {
      const rows = made.flatMap((c: { id: string }) =>
        sections.map((name, i) => ({ class_id: c.id, name, sort_order: i })))
      const { error: secErr } = await sb.from('sections').insert(rows)
      if (secErr) throw new Error(secErr.message)
    }
  }
}

export async function listClassesAll(): Promise<ClassFull[]> {
  const sb = requireSupabase()
  return unwrap(await sb.from('classes').select('id, name, level_order, active').order('level_order'))
}

export async function createClass(name: string, levelOrder: number): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('classes').insert({ name, level_order: levelOrder })
  if (error) throw new Error(error.message)
}

export async function setClassActive(id: string, active: boolean): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('classes').update({ active }).eq('id', id).select('id'),
    'The change to this class')
}

export async function createSection(classId: string, name: string, sortOrder = 0): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('sections').insert({ class_id: classId, name, sort_order: sortOrder })
  if (error) throw new Error(error.message)
}

export async function listProfiles(): Promise<ProfileRow[]> {
  const sb = requireSupabase()
  return unwrap(await sb.from('profiles').select('id, full_name, role, active, staff_id').order('full_name'))
}

export async function updateProfileRole(id: string, role: string): Promise<void> {
  const sb = requireSupabase()
  // The one that made a broken teacher login look like a working one: when the
  // create-teacher Edge Function is not deployed, the fallback used to create the
  // auth user with no school_id, so no profile row existed and this update matched
  // nothing — silently. The signUp now passes school_id; this makes the failure
  // loud if it ever happens again.
  await mustWrite(
    await sb.from('profiles').update({ role }).eq('id', id).select('id'),
    'That login\u2019s role')
}

export async function setProfileActive(id: string, active: boolean): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('profiles').update({ active }).eq('id', id).select('id'),
    'The change to that login')
}

// ---- Staff ----
export interface StaffRow {
  id: string; full_name: string; designation: string | null; employee_no: string | null
  mobile: string | null; whatsapp: string | null; cnic: string | null
  joined_on: string | null; dob: string | null; status: string; profile_id: string | null
  /** A storage path, for the ID card. Written only by fn_set_staff_photo. */
  photo_path: string | null
}
export interface StaffInput {
  full_name: string; designation?: string | null; employee_no?: string | null
  mobile?: string | null; whatsapp?: string | null; cnic?: string | null; joined_on?: string | null
  /** Added in 0050 for the Birthdays screen. Read-only would make that screen
   *  permanently empty for staff, which is the half-wired trap this project
   *  keeps falling into. */
  dob?: string | null
}
export interface SectionTeacherRow { id: string; name: string; class_teacher_id: string | null }

/** A staff row as the roster returns it: the record, plus the two things the
 *  old screen could not see — whether the login works, and what the person
 *  still holds. */
export interface StaffRosterRow extends StaffRow {
  left_on: string | null
  /** null = no account at all; false = account switched off. */
  login_active: boolean | null
  login_role: string | null
  /** "Class 1-A, Class 2-B", or null. */
  class_teacher_of: string | null
  /** Teaching assignments in the CURRENT session. */
  assignments: number
}

export interface ClassPhotoRow {
  student_id: string; full_name: string; roll_no: string | null; photo_path: string | null
}

/**
 * Photograph paths for a list of pupils already on screen.
 *
 * A separate select rather than an extra column on `fn_student_page`: adding a
 * column to a `returns table` function means dropping and recreating it, and
 * re-typing that body by hand is how a stack of earlier fixes gets silently
 * reverted. RLS scopes the select, so it cannot return another school's rows.
 *
 * Returns an empty map on failure — a roster without faces is still a roster,
 * and a page that refuses to load because a photograph could not be looked up
 * would be a far worse defect than a missing face.
 */
export async function getStudentPhotoPaths(ids: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>()
  if (ids.length === 0) return out
  const sb = requireSupabase()
  const { data, error } = await sb.from('students').select('id, photo_path').in('id', ids)
  if (error) return out
  for (const r of (data ?? []) as { id: string; photo_path: string | null }[]) {
    if (r.photo_path) out.set(r.id, r.photo_path)
  }
  return out
}

/** Every pupil in a class with their photo PATH, in one call, so the whole class
 *  can be signed in a single createSignedUrls request rather than forty. */
export async function getClassPhotoPaths(
  classId: string, sectionId: string | null,
): Promise<ClassPhotoRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.rpc('fn_class_photo_paths', { p_class_id: classId, p_section_id: sectionId }))
  return (rows ?? []).map((r) => ({
    student_id: r.student_id,
    full_name: r.full_name,
    roll_no: r.roll_no ?? null,
    photo_path: r.photo_path ?? null,
  }))
}

export interface StaffLeaveResult {
  staff_name: string
  left_on: string
  login_revoked: boolean
  had_login: boolean
  sections_vacated: string
  sections_count: number
  assignments_removed: number
}

/** Staff WITH their login state and what they still hold.
 *
 *  Replaced a plain `from('staff')` select, which could not see whether a
 *  "deactivated" member of staff could still log in — that fact lives in
 *  profiles, and PostgREST cannot embed it unambiguously because staff and
 *  profiles reference each other twice (staff.profile_id, profiles.staff_id).
 *  The screen was therefore unable to show the one thing that mattered. */
export async function getStaffRoster(): Promise<StaffRosterRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(await sb.rpc('fn_staff_roster'))
  // Photo paths come from a second, tiny select rather than from the roster
  // function. Adding a column to a `returns table` function means dropping and
  // recreating it, and re-typing that body by hand is how five migrations' worth
  // of fixes get silently reverted. Staff is a small table and RLS scopes it, so
  // one extra round trip is the cheaper risk. Failure here is non-fatal: a
  // roster with no faces is still a roster.
  const photos = new Map<string, string | null>()
  const ph = await sb.from('staff').select('id, photo_path')
  if (!ph.error) {
    for (const p of (ph.data ?? []) as { id: string; photo_path: string | null }[]) {
      photos.set(p.id, p.photo_path ?? null)
    }
  }
  return (rows ?? []).map((r) => ({
    photo_path: photos.get(r.id) ?? null,
    id: r.id,
    full_name: r.full_name,
    designation: r.designation ?? null,
    employee_no: r.employee_no ?? null,
    mobile: r.mobile ?? null,
    whatsapp: r.whatsapp ?? null,
    cnic: r.cnic ?? null,
    joined_on: r.joined_on ?? null,
    dob: r.dob ?? null,
    left_on: r.left_on ?? null,
    status: r.status,
    profile_id: r.profile_id ?? null,
    // Deliberately NOT coalesced to false. null means "no account at all",
    // false means "account switched off", and the screen says different things
    // about them.
    login_active: r.login_active === null || r.login_active === undefined ? null : !!r.login_active,
    login_role: r.login_role ?? null,
    class_teacher_of: r.class_teacher_of ?? null,
    assignments: Number(r.assignments ?? 0),
  }))
}

/** Record a member of staff leaving: the date, the revoked login, the vacated
 *  class-teacher slots and the dropped current-session assignments, in one
 *  transaction. Returns a summary of what it actually changed so the screen can
 *  tell the principal which classes now need somebody. */
export async function staffLeave(
  staffId: string, leftOn: string, reason: string | null,
): Promise<StaffLeaveResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_leave', {
    p_staff_id: staffId, p_left_on: leftOn, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    staff_name: r.staff_name ?? '',
    left_on: r.left_on ?? leftOn,
    login_revoked: !!r.login_revoked,
    had_login: !!r.had_login,
    sections_vacated: r.sections_vacated ?? '',
    sections_count: Number(r.sections_count ?? 0),
    assignments_removed: Number(r.assignments_removed ?? 0),
  }
}

export async function staffRejoin(
  staffId: string, reason: string | null,
): Promise<{ staff_name: string; login_restored: boolean; had_login: boolean }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_rejoin', {
    p_staff_id: staffId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    staff_name: r.staff_name ?? '',
    login_restored: !!r.login_restored,
    had_login: !!r.had_login,
  }
}

/** The access switch on its own — suspension without falsifying the employment
 *  record, and the remedy for staff the old Deactivate button left able to
 *  log in. */
export async function staffSetLoginActive(
  staffId: string, active: boolean, reason: string | null,
): Promise<{ staff_name: string; login_active: boolean; changed: boolean }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_set_login_active', {
    p_staff_id: staffId, p_active: active, p_reason: reason,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    staff_name: r.staff_name ?? '',
    login_active: !!r.login_active,
    changed: !!r.changed,
  }
}

export async function createStaff(input: StaffInput): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('staff').insert({
    full_name: input.full_name, designation: input.designation || null, employee_no: input.employee_no || null,
    mobile: input.mobile || null, whatsapp: input.whatsapp || null, cnic: input.cnic || null,
    joined_on: input.joined_on || null, dob: input.dob || null,
  }).select('id').single()
  if (error) throw new Error(error.message)
  return (data as { id: string }).id
}

export async function updateStaff(id: string, patch: Partial<StaffInput>): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('staff').update(patch).eq('id', id).select('id'),
    'The change to this staff member')
}

// setStaffStatus is deliberately gone. It wrote `status = 'inactive'` and
// nothing anywhere read staff.status, so the button it powered looked like it
// closed a departed teacher's access and did not: access is gated on
// profiles.active. 0053 replaces it with staffLeave / staffRejoin /
// staffSetLoginActive, and adds a CHECK constraint that would now reject
// 'inactive' outright.

export async function linkStaffProfile(staffId: string, profileId: string | null): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_link_staff_profile', { p_staff_id: staffId, p_profile_id: profileId })
  if (error) throw new Error(error.message)
}

export async function listSectionTeachers(classId: string): Promise<SectionTeacherRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('sections').select('id, name, class_teacher_id').eq('class_id', classId).order('sort_order'),
  )
}

export async function assignClassTeacher(sectionId: string, staffId: string | null): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('sections').update({ class_teacher_id: staffId })
      .eq('id', sectionId).select('id'),
    'The class teacher')
}

// ---- Teacher portal: assignments, self-attendance, check-in ----
export interface MyAssignment {
  class_id: string; class_name: string; level_order: number
  section_id: string | null; section_name: string | null
}
export async function getMyAssignments(): Promise<MyAssignment[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(await sb.rpc('fn_my_assignments'))
  return (rows ?? []).map((r) => ({
    class_id: r.class_id, class_name: r.class_name, level_order: Number(r.level_order ?? 0),
    section_id: r.section_id ?? null, section_name: r.section_name ?? null,
  }))
}

export interface TeacherAssignmentRow {
  id: string; staff_id: string; staff_name: string
  class_id: string; class_name: string; section_id: string | null; section_name: string | null
}
export async function listTeacherAssignments(sessionId: string): Promise<TeacherAssignmentRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('teacher_assignments')
      .select('id, staff_id, class_id, section_id, staff(full_name), classes(name, level_order), sections(name)')
      .eq('session_id', sessionId),
  )
  return rows.map((r) => ({
    id: r.id, staff_id: r.staff_id, staff_name: r.staff?.full_name ?? '—',
    class_id: r.class_id, class_name: r.classes?.name ?? '—',
    section_id: r.section_id ?? null, section_name: r.sections?.name ?? null,
  })).sort((a, b) => a.staff_name.localeCompare(b.staff_name))
}

export async function assignTeacher(
  staffId: string, sessionId: string, classId: string, sectionId: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('teacher_assignments')
    .insert({ staff_id: staffId, session_id: sessionId, class_id: classId, section_id: sectionId })
  if (error && !/duplicate key/i.test(error.message)) throw new Error(error.message)
}
export async function removeTeacherAssignment(id: string): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('teacher_assignments').delete().eq('id', id).select('id'),
    'Removing that assignment')
}

/** Assign (or clear, staffId=null) a class teacher for a (class, section-or-null)
 *  atomically: assignment row for portal scoping + class_teacher_id for result cards. */
export async function setClassTeacher(
  staffId: string | null, sessionId: string, classId: string, sectionId: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_class_teacher', {
    p_staff_id: staffId, p_session_id: sessionId, p_class_id: classId, p_section_id: sectionId,
  })
  if (error) throw new Error(error.message)
}

export interface CheckinCode {
  id: string; code: string; label: string | null
  valid_from: string | null; valid_to: string | null; active: boolean
  /** A rotating code is shown on a screen and changes every 30 seconds; a static
   *  one is printed on a poster, and a photograph of that works for ever. */
  rotating: boolean
}
export async function generateCheckinCode(
  label: string, validFrom: string | null, validTo: string | null,
  deactivateOthers = true, rotating = false,
): Promise<{ id: string; code: string; rotating: boolean }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_generate_checkin_code', {
    p_label: label, p_valid_from: validFrom, p_valid_to: validTo,
    p_deactivate_others: deactivateOthers, p_rotating: rotating,
  })
  if (error) throw new Error(error.message)
  return data as { id: string; code: string; rotating: boolean }
}
export async function listCheckinCodes(): Promise<CheckinCode[]> {
  const sb = requireSupabase()
  // Deliberately NOT selecting `secret`. The column is readable by the office
  // through RLS, and a rotating code whose seed reaches a browser is not a
  // rotating code — so the seed must never be in a network response the school's
  // own screen renders.
  return unwrap(
    await sb.from('staff_checkin_codes')
      .select('id, code, label, valid_from, valid_to, active, rotating')
      .order('created_at', { ascending: false }),
  )
}

/** What the screen at the gate should render right now. Polled, because the token
 *  changes every 30 seconds and the secret it is derived from stays in the
 *  database. `status: 'none'` means no active code — the school has not set one up. */
export interface CheckinDisplay {
  status: 'none' | 'static' | 'rotating'
  code?: string
  label?: string | null
  rotating?: boolean
  token?: string
  period_seconds?: number
  /** Seconds this token still has. Refresh on it rather than on a fixed timer, so
   *  the screen never shows a token that has already stopped working. */
  expires_in?: number
  valid_to?: string | null
}
export async function getCheckinDisplay(): Promise<CheckinDisplay> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_checkin_display')
  if (error) throw new Error(error.message)
  return data as CheckinDisplay
}

export interface CheckInResult {
  status: 'ok' | 'already' | 'out' | 'office_marked'
  checked_at: string
  checked_out_at?: string | null
  attendance_status?: string
  late_minutes?: number | null
  worked_minutes?: number | null
  reason?: string | null
  rotating?: boolean
}

/** Record a check-in (or, on the second scan of the day, a check-out).
 *
 *  The database RETURNS refusals rather than raising them, because a refusal has
 *  to leave a durable row in the attempt log and a raise would roll that row back
 *  with it. This wrapper turns a refusal back into a thrown error, so no caller
 *  can quietly treat one as a successful check-in. */
export async function staffCheckIn(
  code: string, lat: number | null, lng: number | null, device: string | null,
): Promise<CheckInResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_check_in', {
    p_code: code, p_lat: lat, p_lng: lng, p_device: device,
  })
  if (error) throw new Error(error.message)
  const res = (data ?? {}) as Record<string, any>
  if (res.status === 'refused') {
    throw new Error(res.message || 'That check-in was not accepted.')
  }
  return res as CheckInResult
}

export interface StaffDayRow {
  staff_id: string; full_name: string; designation: string | null; employee_no: string | null
  status: string
  checked_at: string | null; checked_out_at: string | null
  late_minutes: number | null; worked_minutes: number | null
  source: string | null
  /** Whether a check-in code was actually presented. The forged rows the old
   *  policy allowed said source 'qr' with no code at all, and nothing displayed
   *  it — which is why the loophole survived. */
  scanned: boolean
  code_label: string | null
  code_window: number | null
  device: string | null
  reason: string | null
  marked_by_name: string | null
}

/** The day's staff register: everybody, marked or not. */
export async function getStaffAttendanceDay(date: string | null): Promise<StaffDayRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_attendance_day', { p_date: date })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, any>[]).map((r) => ({
    staff_id: r.staff_id, full_name: r.full_name, designation: r.designation ?? null,
    employee_no: r.employee_no ?? null, status: r.status,
    checked_at: r.checked_at ?? null, checked_out_at: r.checked_out_at ?? null,
    late_minutes: r.late_minutes == null ? null : Number(r.late_minutes),
    worked_minutes: r.worked_minutes == null ? null : Number(r.worked_minutes),
    source: r.source ?? null, scanned: !!r.scanned,
    code_label: r.code_label ?? null,
    code_window: r.code_window == null ? null : Number(r.code_window),
    device: r.device ?? null, reason: r.reason ?? null,
    marked_by_name: r.marked_by_name ?? null,
  }))
}

export interface CheckinAttempt {
  id: number; staff_name: string | null; reason: string
  presented: string | null; device: string | null; created_at: string
}

/** Refused check-ins. Somebody trying an old photograph forty times is only
 *  visible if the school can see this. */
export async function listCheckinAttempts(limit = 50): Promise<CheckinAttempt[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_checkin_attempts', { p_limit: limit })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, any>[]).map((r) => ({
    id: Number(r.id), staff_name: r.staff_name ?? null, reason: r.reason,
    presented: r.presented ?? null, device: r.device ?? null, created_at: r.created_at,
  }))
}

export async function setStaffAttendance(
  staffId: string, date: string, status: AttendanceStatus, reason: string,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_staff_attendance', {
    p_staff_id: staffId, p_date: date, p_status: status, p_reason: reason,
  })
  if (error) throw new Error(error.message)
}

export async function getStaffAttendanceSummary(
  staffId: string, from: string, to: string,
): Promise<AttendanceSummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_attendance_summary', { p_staff_id: staffId, p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return data as AttendanceSummary
}

export async function getStaffMonthAttendance(
  staffId: string, month: string,
): Promise<{ attendance_date: string; status: string; source: string; checked_at: string | null }[]> {
  const sb = requireSupabase()
  const [y, m] = month.split('-').map(Number)
  const last = `${month}-${String(new Date(y, m, 0).getDate()).padStart(2, '0')}`
  return unwrap(
    await sb.from('staff_attendance')
      .select('attendance_date, status, source, checked_at')
      .eq('staff_id', staffId)
      .gte('attendance_date', `${month}-01`).lte('attendance_date', last)
      .order('attendance_date'),
  )
}

/** Today's check-in row for the current teacher (null if not linked / not checked in). */
export async function getMyTodayCheckin(): Promise<{ attendance_date: string; status: string; checked_at: string | null } | null> {
  const sb = requireSupabase()
  const staffId = (await sb.from('profiles').select('staff_id').eq('id', (await sb.auth.getUser()).data.user?.id ?? '').maybeSingle()).data?.staff_id
  if (!staffId) return null
  const { data } = await sb.from('staff_attendance')
    .select('attendance_date, status, checked_at')
    .eq('staff_id', staffId).eq('attendance_date', pkToday()).maybeSingle()
  return data ?? null
}
/** "Today" in Pakistan time (matches the server's `now() at time zone 'Asia/Karachi'`
 *  used by fn_staff_check_in), so the check-in card doesn't disagree overnight. */
function pkToday(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' })
}

/** Create a teacher/staff login via the create-teacher Edge Function (owner/
 *  principal only; enforced server-side). Throws a helpful message if the
 *  function isn't deployed. */
export interface CreateTeacherInput { email: string; password: string; full_name: string; role?: string }
export async function createTeacherLogin(input: CreateTeacherInput): Promise<{ id: string; email: string; role: string }> {
  const sb = requireSupabase()
  const role = input.role ?? 'class_teacher'
  const email = input.email.trim().toLowerCase()
  const fullName = input.full_name.trim()

  // Preferred path: the create-teacher Edge Function. It uses the service key so
  // the login is created already-confirmed (works regardless of project settings).
  const { data, error } = await sb.functions.invoke('create-teacher', {
    body: { email, password: input.password, full_name: fullName, role },
  })
  if (!error) return data as { id: string; email: string; role: string }

  // The function is deployed but rejected the request → surface its real reason.
  if ((error as any).name === 'FunctionsHttpError') {
    let msg = error.message
    try { const ctx = await (error as any).context?.json?.(); if (ctx?.error) msg = ctx.error } catch { /* ignore */ }
    throw new Error(msg)
  }

  // Function not deployed / unreachable.
  //
  // This used to create the login here with a throwaway client, passing
  // school_id AND role in signUp's user_metadata. That was the hole 0065
  // closed: user_metadata is written by the browser, so handle_new_user
  // believing a role in it meant ANY signed-in user — a parent — could sign up
  // again asking for 'principal' and get it, active. The trigger no longer reads
  // that field for authorisation, so this path cannot work and must not pretend
  // to.
  //
  // The invitation is the replacement and it is strictly better: creating one is
  // an authorised act by an owner or principal, checked by RLS, and the person
  // chooses their own password instead of a clerk inventing one and reading it
  // out over the phone.
  throw new Error(
    'The create-teacher function is not deployed, so a login cannot be made here. '
    + `Invite ${email} instead — they set their own password, and the role you choose is `
    + 'applied when they sign up. (Deploy the create-teacher function once if you would '
    + 'rather create logins directly.)',
  )
}

export interface PendingInvite {
  id: string
  email: string
  role: string
  full_name: string | null
  invited_by: string | null
  created_at: string
  expires_at: string
  expired: boolean
}

/**
 * Invite somebody to this school with a role of your choosing.
 *
 * The role is stored on the invitation, not sent by the browser at signup — that
 * is the whole point. When they sign up with this address the trigger reads the
 * role from the invitation row an owner or principal created.
 *
 * An owner cannot be invited: the school's top privilege must not sit behind an
 * email address. Promote an existing account on this screen instead.
 */
export async function inviteUser(
  email: string, role: string, fullName?: string,
): Promise<{ id: string; email: string; role: string; expires_at: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_invite_user', {
    p_email: email.trim(), p_role: role,
    p_full_name: fullName?.trim() || null,
  })
  if (error) throw new Error(error.message)
  return data as { id: string; email: string; role: string; expires_at: string }
}

export async function listPendingInvites(): Promise<PendingInvite[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_pending_invites')
  if (error) throw new Error(error.message)
  return (data ?? []) as PendingInvite[]
}

export async function revokeInvite(id: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_revoke_invite', { p_id: id })
  if (error) throw new Error(error.message)
}

/**
 * Create a login for a parent and attach it to a family, in one step.
 *
 * Two separate things have to happen and both can fail, so the order matters:
 * the login is created first, then linked. If the link fails the login still
 * exists — which is recoverable (link it from the family sheet) — whereas
 * linking a login that was never created is not.
 *
 * Before migration 0037 this was impossible in two ways: the Edge Function
 * rejected the 'parent' role outright, and nothing anywhere called
 * fn_link_parent, so profiles.family_id was never written and every portal read
 * refused with "Not a parent account".
 */
export async function createParentLogin(input: {
  email: string; password: string; full_name: string; family_id: string
}): Promise<{ id: string; email: string }> {
  const created = await createTeacherLogin({
    email: input.email, password: input.password, full_name: input.full_name, role: 'parent',
  })
  await linkParent(created.id, input.family_id)
  return { id: created.id, email: created.email }
}

/** Attach an existing parent login to a family. */
export async function linkParent(profileId: string, familyId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_link_parent', {
    p_profile_id: profileId, p_family_id: familyId,
  })
  if (error) throw new Error(error.message)
}

export interface FamilyParent {
  profile_id: string; full_name: string | null; email: string | null; active: boolean
}

/** Who can already see this family's portal. Checked before creating another. */
export async function listFamilyParents(familyId: string): Promise<FamilyParent[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_family_parents', { p_family_id: familyId })
  if (error) throw new Error(error.message)
  return (data ?? []) as FamilyParent[]
}

/** Cut a parent's access: detaches the family and deactivates the login. */
export async function unlinkParent(profileId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_unlink_parent', { p_profile_id: profileId })
  if (error) throw new Error(error.message)
}


// ---- Certificates ----
//
// A School Leaving Certificate is the document a Pakistani family cannot enrol a
// child anywhere else without, and it is the school's main lever for unpaid
// fees. Three things follow from that, and all three live in the database rather
// than here: the dues gate, the fact that issuing one RECORDS the leaving, and
// the DUPLICATE marking on a second copy. See docs/CERTIFICATES-DESIGN.md.

export interface IssueCertResult {
  id: string; serial_no: number; cert_type: string; issued_on: string
  is_duplicate: boolean; original_serial_no: number | null
}

/** What the database will do if this certificate is asked for right now —
 *  fetched BEFORE the form is submitted so the clerk sees the refusal as a
 *  condition to resolve rather than as an error after pressing Issue. */
export interface CertReadiness {
  student_name: string
  balance: number
  status: string | null
  left_on: string | null
  /** Whether dues are checked for this type at all — only `leaving` is gated. */
  dues_gate: boolean
  blocked_by_dues: boolean
  would_be_duplicate: boolean
  original_serial_no: number | null
}

export interface CertificateRow {
  id: string; cert_type: string; serial_no: number; issued_on: string
  student_id: string | null
  student_name: string | null; gr_no: string | null; data: Record<string, any>
  /** Read LIVE, not from the frozen snapshot. A certificate's wording must never
   *  drift on a reprint, but an ID card exists to let somebody recognise the
   *  child holding it — so it shows the photograph on file today, not the one
   *  that was on file the day the card was first issued. */
  photo_path: string | null
  is_duplicate: boolean
  original_serial_no: number | null
  /** What was outstanding when it was issued, and whether that was cleared.
   *  A released-under-override leaving certificate is a fact the register has
   *  to show, not something to find out about later. */
  dues_cleared: boolean
  balance_at_issue: number
  cancelled_at: string | null
  cancel_reason: string | null
  issued_by_name: string | null
}

export async function certificateReadiness(
  studentId: string, certType: string,
): Promise<CertReadiness> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_certificate_readiness', {
    p_student_id: studentId, p_cert_type: certType,
  })
  if (error) throw new Error(error.message)
  const d = (data ?? {}) as Record<string, any>
  return {
    student_name: d.student_name ?? '',
    balance: Number(d.balance ?? 0),
    status: d.status ?? null,
    left_on: d.left_on ?? null,
    dues_gate: !!d.dues_gate,
    blocked_by_dues: !!d.blocked_by_dues,
    would_be_duplicate: !!d.would_be_duplicate,
    original_serial_no: d.original_serial_no == null ? null : Number(d.original_serial_no),
  }
}

/** Issue a certificate. For `leaving`, `leavingOn` and `leavingReason` are
 *  REQUIRED by the database — issuing one records the child as having left, so
 *  there is deliberately no way to produce one without stating when and why. */
export async function issueCertificate(
  certType: string, studentId: string, data: Record<string, any>,
  opts: {
    leavingOn?: string | null
    leavingReason?: string | null
    leavingStatus?: string
    overrideDues?: boolean
    overrideReason?: string | null
  } = {},
): Promise<IssueCertResult> {
  const sb = requireSupabase()
  const { data: res, error } = await sb.rpc('fn_issue_certificate', {
    p_cert_type: certType, p_student_id: studentId, p_data: data,
    p_leaving_on: opts.leavingOn ?? null,
    p_leaving_reason: opts.leavingReason ?? null,
    p_leaving_status: opts.leavingStatus ?? 'withdrawn',
    p_override_dues: opts.overrideDues ?? false,
    p_override_reason: opts.overrideReason ?? null,
  })
  if (error) throw new Error(error.message)
  const r = (res ?? {}) as Record<string, any>
  return {
    id: r.id, serial_no: Number(r.serial_no), cert_type: r.cert_type, issued_on: r.issued_on,
    is_duplicate: !!r.is_duplicate,
    original_serial_no: r.original_serial_no == null ? null : Number(r.original_serial_no),
  }
}

/** Mark a certificate cancelled. Owner or principal only, and the reason is
 *  required — a cancelled serial is a fact somebody may later have to explain.
 *  `certificates` itself is append-only; this writes a separate row. */
export async function cancelCertificate(certificateId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_cancel_certificate', {
    p_certificate_id: certificateId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
}

// ---- Audit log (owner/principal read-only via RLS) ----
export interface AuditRow {
  id: number; actor: string | null; actor_role: string | null; action: string
  entity: string; entity_id: string | null; reason: string | null; created_at: string
}
export async function listAuditLog(limit = 200): Promise<AuditRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('audit_log')
      .select('id, actor, actor_role, action, entity, entity_id, reason, created_at')
      .order('created_at', { ascending: false }).limit(limit),
  )
}

// ---- Full data export (backup) ----
/** Every domain table, in dependency-ish order, for a complete backup. */
export const EXPORT_TABLES = [
  'school_settings', 'academic_sessions', 'campuses', 'shifts', 'classes', 'sections', 'subjects',
  'profiles', 'staff', 'students', 'guardians', 'enrollments',
  'fee_heads', 'fee_structures', 'student_fee_items', 'discounts',
  'invoices', 'invoice_lines', 'payments', 'payment_allocations', 'adjustments',
  'attendance_daily', 'assessments', 'exam_terms', 'exam_subjects', 'mark_entries',
  'result_cards', 'certificates', 'counters', 'audit_log',
  // Added by 0019/0022 and previously missing here, which made a "complete
  // backup" silently omit family links, teacher assignments and staff attendance.
  'student_links', 'teacher_assignments', 'staff_attendance', 'staff_checkin_codes',
] as const

export interface ExportResult {
  exported_at: string
  tables: Record<string, any[]>
  errors: Record<string, string>
  counts: Record<string, number>
}

async function fetchAllRows(table: string): Promise<any[]> {
  const sb = requireSupabase()
  const page = 1000
  const out: any[] = []
  for (let from = 0; ; from += page) {
    const { data, error } = await sb.from(table).select('*').range(from, from + page - 1)
    if (error) throw new Error(error.message)
    out.push(...(data ?? []))
    if (!data || data.length < page) break
  }
  return out
}

/** Read every table the current user is allowed to (RLS applies) into one object.
 *  Tables that error (e.g. finance tables for a non-finance user) are recorded in
 *  `errors` rather than aborting the whole export. */
export async function exportAllData(
  exportedAt: string, onProgress?: (table: string, i: number, n: number) => void,
): Promise<ExportResult> {
  const tables: Record<string, any[]> = {}
  const errors: Record<string, string> = {}
  const counts: Record<string, number> = {}
  for (let i = 0; i < EXPORT_TABLES.length; i++) {
    const t = EXPORT_TABLES[i]
    onProgress?.(t, i, EXPORT_TABLES.length)
    try {
      const rows = await fetchAllRows(t)
      tables[t] = rows
      counts[t] = rows.length
    } catch (e) {
      errors[t] = (e as Error).message
    }
  }
  return { exported_at: exportedAt, tables, errors, counts }
}

// ---- Dashboard ----
export interface DashboardSummary {
  active_students: number
  new_admissions_month: number
  attendance: { marked: number; present: number; absent: number; leave: number; late: number; half_day: number }
  finance_visible: boolean
  collected_today: number | null
  collected_month: number | null
  outstanding: number | null
  defaulters: number | null
  /**
   * How many students actually have a CHARGING challan this month.
   *
   * Exists because "outstanding: 0" is ambiguous: it means both "everyone has
   * paid" and "nobody was ever billed", and the second was being rendered as
   * good news in green. Zero-value challans — which a class with no fee
   * structure produces — do not count.
   */
  billed_students_month: number | null
  /** Classes with active students and no fee structure: the root cause of a
   *  Rs 0 challan. */
  classes_without_fee: number | null
  /** False when no current academic session is set, which otherwise makes every
   *  session-scoped figure silently zero. */
  session_set: boolean
}

export async function getDashboardSummary(): Promise<DashboardSummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_dashboard_summary')
  if (error) throw new Error(error.message)
  return data as DashboardSummary
}

/** The certificate register. Goes through fn_certificate_register rather than
 *  selecting the table, because a register that does not show which serials were
 *  cancelled, which are duplicates and which were released over unpaid dues is
 *  not a register — it is a list. */
export async function listCertificates(limit = 50): Promise<CertificateRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_certificate_register', { p_limit: limit })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, any>[]).map((r) => ({
    id: r.id, cert_type: r.cert_type, serial_no: Number(r.serial_no), issued_on: r.issued_on,
    student_id: r.student_id ?? null,
    student_name: r.student_name ?? r.data?.student_name ?? null,
    gr_no: r.gr_no ?? r.data?.gr_no ?? null,
    data: r.data ?? {},
    photo_path: r.photo_path ?? null,
    is_duplicate: !!r.is_duplicate,
    original_serial_no: r.original_serial_no == null ? null : Number(r.original_serial_no),
    dues_cleared: !!r.dues_cleared,
    balance_at_issue: Number(r.balance_at_issue ?? 0),
    cancelled_at: r.cancelled_at ?? null,
    cancel_reason: r.cancel_reason ?? null,
    issued_by_name: r.issued_by_name ?? null,
  }))
}

// ---- Refundable deposits ---------------------------------------------------
//
// A security deposit is the one kind of money a school takes that is NOT its
// own. Before 0060 it counted as profit: a Rs 5,000 deposit made a proprietor's
// "what did we keep" figure Rs 5,000 too high, and at 200 pupils that is a
// million rupees they might pay a salary out of.

export interface DepositHeldRow {
  student_id: string; full_name: string; gr_no: string | null
  father_name: string | null; class_name: string | null
  status: string; left_on: string | null
  collected: number; refunded: number; held: number
}
export interface DepositRefundResult {
  refund_id: string
  student_name: string
  amount: number
  /** Netted against what the family owed, as an ADJUSTMENT — so no cash report
   *  gains money that never crossed the counter. */
  applied_to_dues: number
  paid_out: number
  still_held: number
  was_enrolled: boolean
}

/** Refundable money the school is holding for one pupil. Derived from
 *  allocations against deposit invoices, less refunds — never stored, so it
 *  cannot drift from the ledger. */
export async function getDepositHeld(studentId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_deposit_held', { p_student_id: studentId })
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

/**
 * Charge a deposit. It goes on its OWN challan, by construction.
 *
 * Not a choice of layout: `payment_allocations` allocates to an invoice, not a
 * line, so on a mixed challan a part-payment could not be split into "deposit"
 * and "tuition" — and any splitting rule would be one a parent could argue with
 * and the school could not defend.
 */
export async function chargeDeposit(
  studentId: string, feeHeadId: string, amount: number,
  dueDate?: string | null, note?: string | null,
): Promise<{ invoice_id: string; amount: number; fee_head: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_charge_deposit', {
    p_student_id: studentId, p_fee_head_id: feeHeadId, p_amount: amount,
    p_due_date: dueDate ?? null, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return { invoice_id: r.invoice_id, amount: Number(r.amount ?? 0), fee_head: r.fee_head ?? '' }
}

/**
 * Refund a deposit, netting arrears first.
 *
 * `amount` omitted means everything held. `netAgainstDues` is the normal case
 * and is what a clerk says at the counter: "you owe 3,000, your deposit is
 * 5,000, here is 2,000 back."
 */
export async function refundDeposit(input: {
  studentId: string
  amount?: number | null
  netAgainstDues?: boolean
  method?: string
  reason?: string | null
}): Promise<DepositRefundResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_refund_deposit', {
    p_student_id: input.studentId,
    p_amount: input.amount ?? null,
    p_net_against_dues: input.netAgainstDues ?? true,
    p_method: input.method ?? 'cash',
    p_reason: input.reason ?? null,
  })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, any>
  return {
    refund_id: r.refund_id,
    student_name: r.student_name ?? '',
    amount: Number(r.amount ?? 0),
    applied_to_dues: Number(r.applied_to_dues ?? 0),
    paid_out: Number(r.paid_out ?? 0),
    still_held: Number(r.still_held ?? 0),
    was_enrolled: !!r.was_enrolled,
  }
}

/** Everyone the school is holding refundable money for — INCLUDING pupils who
 *  have left and not been refunded, because that is exactly what is still owed. */
export async function listDepositsHeld(): Promise<DepositHeldRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(await sb.rpc('fn_deposits_held'))
  return (rows ?? []).map((r) => ({
    student_id: r.student_id, full_name: r.full_name,
    gr_no: r.gr_no ?? null, father_name: r.father_name ?? null,
    class_name: r.class_name ?? null,
    status: r.status, left_on: r.left_on ?? null,
    collected: Number(r.collected ?? 0),
    refunded: Number(r.refunded ?? 0),
    held: Number(r.held ?? 0),
  }))
}

// ---- Families: the payer at the counter -----------------------------------
// A father with three children hands over one bundle of cash. These back the
// one-payment-one-receipt flow; see docs/10-MONEY-ENGINE-V2.md.

export interface FamilyHit {
  family_id: string
  head_name: string
  head_cnic: string | null
  phone: string | null
  children: number
  outstanding: number
  credit: number
}

export interface FamilyInvoice {
  invoice_id: string
  period_month: string | null
  due_date: string | null
  charge: number
  allocated: number
  outstanding: number
  status: string
}

export interface FamilyChild {
  student_id: string
  full_name: string
  gr_no: string | null
  status: string
  balance: number
  invoices: FamilyInvoice[]
}

export interface FamilySheet {
  family: {
    id: string
    head_name: string
    head_cnic: string | null
    phone: string | null
    whatsapp: string | null
    address: string | null
  }
  credit: number
  outstanding: number
  children: FamilyChild[]
}

export interface FamilyPaymentResult {
  payment_id: string
  receipt_no: number
  allocated: number
  credit: number
  family_outstanding?: number
  pending: boolean
}

/** One search box: CNIC, phone, parent name, student name or GR number. */
export async function findFamily(q: string): Promise<FamilyHit[]> {
  const sb = requireSupabase()
  const term = q.trim()
  if (!term) return []
  const { data, error } = await sb.rpc('fn_find_family', { p_query: term })
  if (error) throw new Error(error.message)
  return (data ?? []) as FamilyHit[]
}

export async function getFamilySheet(familyId: string): Promise<FamilySheet> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_family_sheet', { p_family_id: familyId })
  if (error) throw new Error(error.message)
  return data as FamilySheet
}

/** One payment across every child. Allocation is oldest month first. */
export async function recordFamilyPayment(
  familyId: string, amount: number, method: string, note?: string, pending = false,
): Promise<FamilyPaymentResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_family_payment', {
    p_family_id: familyId, p_amount: amount, p_method: method,
    p_note: note ?? null, p_pending: pending,
  })
  if (error) throw new Error(error.message)
  return data as FamilyPaymentResult
}

/** The family a student belongs to — used to jump from a profile to the till. */
export async function getStudentFamilyId(studentId: string): Promise<string | null> {
  const sb = requireSupabase()
  const { data, error } = await sb
    .from('students').select('family_id').eq('id', studentId).single()
  if (error) throw new Error(error.message)
  return (data?.family_id as string | null) ?? null
}

// ---- Portal: one login, role decides everything ---------------------------

export interface PortalChild {
  student_id: string
  full_name: string
  gr_no: string | null
  class_name: string | null
  section_name: string | null
  status: string
}

export interface PortalClass {
  class_id: string
  class_name: string
  level_order: number
  section_id: string | null
  section_name: string | null
}

export interface PortalMe {
  profile_id: string
  full_name: string
  role: string
  school_name: string | null
  children: PortalChild[]
  classes: PortalClass[]
}

export interface PortalInvoice {
  period_month: string | null
  due_date: string | null
  charge: number
  paid: number
  outstanding: number
  status: string
}

export interface PortalReceipt {
  receipt_no: number
  amount: number
  method: string
  paid_on: string
  received_by: string | null
}

export interface PortalFees {
  student_id: string
  balance: number
  family_outstanding: number
  family_credit: number
  invoices: PortalInvoice[]
  receipts: PortalReceipt[]
}

export interface PortalAttendance {
  from: string
  to: string
  present: number
  marked: number
  percent: number | null
  days: { date: string; status: string }[]
}

export interface PortalResult {
  result_card_id: string
  term: string
  withheld: boolean
  message?: string
  obtained_marks?: number
  total_marks?: number
  percentage?: number
  grade?: string | null
  position?: number | null
  attendance_pct?: number | null
  subjects?: { subject: string; max: number; marks: number | null; is_absent: boolean; grade: string | null }[]
  issued_at: string | null
}

export async function getPortalMe(): Promise<PortalMe> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_portal_me')
  if (error) throw new Error(error.message)
  return data as PortalMe
}

export async function getPortalChildFees(studentId: string): Promise<PortalFees> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_portal_child_fees', { p_student_id: studentId })
  if (error) throw new Error(error.message)
  return data as PortalFees
}

export async function getPortalChildAttendance(
  studentId: string, from: string, to: string,
): Promise<PortalAttendance> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_portal_child_attendance', {
    p_student_id: studentId, p_from: from, p_to: to,
  })
  if (error) throw new Error(error.message)
  return data as PortalAttendance
}

export async function getPortalChildResults(studentId: string): Promise<PortalResult[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_portal_child_results', { p_student_id: studentId })
  if (error) throw new Error(error.message)
  return (data ?? []) as PortalResult[]
}

/** Release / withdraw a term's results to parents (owner & principal only). */
export async function publishResults(examTermId: string, classId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_publish_results', {
    p_exam_term_id: examTermId, p_class_id: classId,
  })
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

export async function unpublishResults(examTermId: string, classId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_unpublish_results', {
    p_exam_term_id: examTermId, p_class_id: classId,
  })
  if (error) throw new Error(error.message)
  return Number(data ?? 0)
}

// ---- Accounts: expenses, other income, profit -----------------------------

export interface ExpenseCategory { id: string; name: string; sort_order: number; active: boolean }
export interface FinanceSummary {
  from: string; to: string
  fee_income: number; other_income: number; total_income: number
  expenses: number; profit: number
  by_category: { category: string; total: number }[]
}
export interface ProfitSnapshot { today: FinanceSummary; month: FinanceSummary; year: FinanceSummary }

export async function listExpenseCategories(): Promise<ExpenseCategory[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('expense_categories').select('id, name, sort_order, active')
      .eq('active', true).order('sort_order'),
  )
}

export async function recordExpense(
  amount: number, categoryId: string | null, spentOn: string,
  payee?: string, method = 'cash', note?: string,
): Promise<{ expense_id: string; voucher_no: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_expense', {
    p_amount: amount, p_category_id: categoryId, p_spent_on: spentOn,
    p_payee: payee ?? null, p_method: method, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { expense_id: string; voucher_no: number }
}

export async function reverseExpense(expenseId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_reverse_expense', { p_expense_id: expenseId, p_reason: reason })
  if (error) throw new Error(error.message)
}

export async function recordOtherIncome(
  amount: number, source: string, receivedOn: string, method = 'cash', note?: string,
): Promise<{ income_id: string; voucher_no: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_other_income', {
    p_amount: amount, p_source: source, p_received_on: receivedOn,
    p_method: method, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { income_id: string; voucher_no: number }
}

/**
 * The twin of reverseExpense, and it was missing for a long time.
 *
 * fn_reverse_other_income has existed since 0030 with zero callers, so a clerk
 * who typed Rs 50,000 of hall rent instead of Rs 5,000 had no way to correct
 * it — the ledger is append-only by design, so there was no edit either. The
 * error sat in the income figure, the profit, the day book and the balance
 * sheet permanently. Found by supabase/check-reachable.sh.
 */
export async function reverseOtherIncome(incomeId: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_reverse_other_income', {
    p_income_id: incomeId, p_reason: reason,
  })
  if (error) throw new Error(error.message)
}

export async function getFinanceSummary(from: string, to: string): Promise<FinanceSummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_finance_summary', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return data as FinanceSummary
}

export async function getProfitSnapshot(): Promise<ProfitSnapshot> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_profit_snapshot')
  if (error) throw new Error(error.message)
  return data as ProfitSnapshot
}

export interface ExpenseRow {
  id: string; spent_on: string; amount: number; payee: string | null
  method: string; note: string | null; voucher_no: number | null
  category_id: string | null; reversal_of: string | null
}

export async function listExpenses(from: string, to: string): Promise<ExpenseRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('expenses')
      .select('id, spent_on, amount, payee, method, note, voucher_no, category_id, reversal_of')
      .gte('spent_on', from).lte('spent_on', to)
      .order('spent_on', { ascending: false }).order('voucher_no', { ascending: false }),
  )
}

export interface OtherIncomeRow {
  id: string; received_on: string; amount: number; source: string
  method: string; note: string | null; voucher_no: number | null
  reversal_of: string | null
}

/**
 * Other income had no read path at all until now, only a write one.
 *
 * recordOtherIncome existed and fed the totals, but nothing ever listed the
 * individual entries, so a wrong one could not be found — let alone reversed.
 * A write-only money ledger is not a ledger. Same shape as listExpenses; the
 * table's own RLS policy already restricts it to owner/principal/accountant.
 */
export async function listOtherIncome(from: string, to: string): Promise<OtherIncomeRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('other_income')
      .select('id, received_on, amount, source, method, note, voucher_no, reversal_of')
      .gte('received_on', from).lte('received_on', to)
      .order('received_on', { ascending: false }).order('voucher_no', { ascending: false }),
  )
}

// ---- Till: the cash drawer ------------------------------------------------

export interface CurrentTill {
  till_id: string; opened_at: string; opening_float: number
  cash_taken: number; all_taken: number; receipts: number; expected_cash: number
}
export interface TillReportRow {
  till_id: string; collector: string; opened_at: string; closed_at: string | null
  opening_float: number; cash_taken: number; all_taken: number
  expected_cash: number | null; counted_cash: number | null
  variance: number | null; variance_reason: string | null; status: string
}

export async function getCurrentTill(): Promise<CurrentTill | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_current_till')
  if (error) throw new Error(error.message)
  return (data ?? null) as CurrentTill | null
}

export async function openTill(openingFloat: number): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_open_till', { p_opening_float: openingFloat })
  if (error) throw new Error(error.message)
  return data as string
}

export async function closeTill(countedCash: number, reason?: string) {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_close_till', {
    p_counted_cash: countedCash, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
  return data as { till_id: string; expected_cash: number; counted_cash: number; variance: number }
}

export async function approveTill(tillId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_approve_till', { p_till_id: tillId })
  if (error) throw new Error(error.message)
}

export async function getTillReport(from: string, to: string): Promise<TillReportRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_till_report', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return (data ?? []) as TillReportRow[]
}

// ---- Outbox: WhatsApp click-to-chat ---------------------------------------

export interface OutboxRow {
  id: string; template_key: string; to_name: string | null; to_phone: string | null
  rendered_text: string; status: string; created_at: string; sent_at: string | null
}

export async function listOutbox(status = 'queued', limit = 100): Promise<OutboxRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('message_outbox')
      .select('id, template_key, to_name, to_phone, rendered_text, status, created_at, sent_at')
      .eq('status', status).order('created_at', { ascending: false }).limit(limit),
  )
}

export async function markMessageSent(id: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_mark_message_sent', { p_id: id, p_channel: 'whatsapp' })
  if (error) throw new Error(error.message)
}

export async function skipMessage(id: string, reason: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_skip_message', { p_id: id, p_reason: reason })
  if (error) throw new Error(error.message)
}

export async function getUnsentReceipts(from: string, to: string) {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_unsent_receipts', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return data as { from: string; to: string; payments: number; receipts_sent: number; receipts_unsent: number }
}

/**
 * A wa.me link with the message pre-filled. Free, no API, no credits — the
 * clerk presses send in WhatsApp. Pakistani numbers are normalised to
 * international form because wa.me rejects a leading 0.
 */
export function whatsappLink(phone: string | null, text: string): string | null {
  if (!phone) return null
  let n = phone.replace(/[^\d]/g, '')
  if (n.startsWith('0')) n = `92${n.slice(1)}`
  else if (!n.startsWith('92') && n.length === 10) n = `92${n}`
  if (n.length < 11) return null
  return `https://wa.me/${n}?text=${encodeURIComponent(text)}`
}

// ---- Reporting area -------------------------------------------------------

export interface LedgerRow {
  entry_date: string
  kind: 'income' | 'expense'
  category: string
  particulars: string
  reference: string
  party: string
  method: string
  debit: number
  credit: number
  recorded_by: string
  is_reversal: boolean
}

/**
 * Debit & credit statement. `kind` narrows it to a detailed income or expense
 * report — one function rather than three, because they are the same rows.
 *
 * Asserted in supabase/tests/reports.sql to net to the same profit the Accounts
 * screen shows. Two screens disagreeing about one month is the fastest way to
 * lose a school's trust.
 */
export async function getLedger(
  from: string, to: string, kind: 'all' | 'income' | 'expense' = 'all',
): Promise<LedgerRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_report_ledger', {
    p_from: from, p_to: to, p_kind: kind,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as LedgerRow),
    debit: Number(r.debit ?? 0),
    credit: Number(r.credit ?? 0),
  }))
}

export interface UnpaidInvoiceRow {
  invoice_id: string
  voucher_code: string | null
  period_label: string
  due_date: string | null
  days_overdue: number
  student_id: string
  student_name: string
  gr_no: string | null
  class_name: string | null
  section_name: string | null
  father_name: string | null
  charge: number
  paid: number
  due: number
}

/** Per CHALLAN, not per student — which is what the defaulter report cannot say. */
export async function getUnpaidInvoices(sessionId: string): Promise<UnpaidInvoiceRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_report_unpaid_invoices', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as UnpaidInvoiceRow),
    days_overdue: Number(r.days_overdue ?? 0),
    charge: Number(r.charge ?? 0),
    paid: Number(r.paid ?? 0),
    due: Number(r.due ?? 0),
  }))
}

export interface DiscountReportRow {
  granted_on: string
  student_id: string
  student_name: string
  gr_no: string | null
  class_name: string | null
  reason_type: string
  is_percent: boolean
  amount: number
  reason: string | null
  status: string
  proposed_by: string
  approved_by: string
  approved_at: string | null
}

/** Money the school chose not to collect, and who signed it off. */
export async function getDiscountReport(
  from: string | null, to: string | null,
): Promise<DiscountReportRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_report_discounts', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as DiscountReportRow),
    amount: Number(r.amount ?? 0),
  }))
}

export interface AdmissionReportRow {
  admitted_on: string
  student_id: string
  student_name: string
  gr_no: string | null
  admission_no: string | null
  father_name: string | null
  gender: string | null
  class_name: string | null
  section_name: string | null
  status: string
  admitted_by: string
}

export async function getAdmissionReport(
  from: string | null, to: string | null,
): Promise<AdmissionReportRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_report_admissions', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return (data ?? []) as AdmissionReportRow[]
}

export interface BalanceSheet {
  as_at: string
  /** Owed to the school on that date, across every student it has ever had. */
  receivable: number
  /** Of the receivable, how much belongs to children no longer on the roll. */
  receivable_off_roll: number
  cash_in: number
  cash_out: number
  cash_position: number
  /** Fees taken for a month not yet billed — a liability, not income. */
  advance_held: number
  fee_receipts: number
  other_income: number
  charges_raised: number
  allocated: number
  students_on_roll: number
  students_owing: number
  /** What the figures do and do not include, straight from SQL. */
  basis: string
}

/**
 * The school's position AS AT one day, not a date range.
 *
 * Every other report here answers "what happened between two dates". This one
 * answers "where did we stand", which cannot be served by summing
 * student_balance() — that is always today's figure, whatever date you print
 * above it. See supabase/migrations/0045_balance_sheet.sql.
 */
export async function getBalanceSheet(asAt: string | null): Promise<BalanceSheet> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_report_balance_sheet', { p_as_at: asAt })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, unknown>
  const num = (k: string) => Number(r[k] ?? 0)
  return {
    as_at: String(r.as_at ?? ''),
    receivable: num('receivable'),
    receivable_off_roll: num('receivable_off_roll'),
    cash_in: num('cash_in'),
    cash_out: num('cash_out'),
    cash_position: num('cash_position'),
    advance_held: num('advance_held'),
    fee_receipts: num('fee_receipts'),
    other_income: num('other_income'),
    charges_raised: num('charges_raised'),
    allocated: num('allocated'),
    students_on_roll: num('students_on_roll'),
    students_owing: num('students_owing'),
    basis: String(r.basis ?? ''),
  }
}

// ---- Global search and birthdays -----------------------------------------

export interface SearchHit {
  kind: 'student' | 'staff' | 'family' | 'challan' | 'receipt' | 'enquiry'
  id: string
  title: string
  subtitle: string
  detail: string
  /** Where this record lives. Comes from SQL so it cannot drift from the list
   *  of things that are searchable. */
  route: string
  /** True when the term matched an identifier exactly; those sort first. */
  exact: boolean
}

/**
 * One box, several kinds of record.
 *
 * What a given user is allowed to find is decided in SQL: a class teacher gets
 * pupils and not the family ledger or the receipt book. Filtering here would be
 * decoration over an open door.
 */
export async function globalSearch(term: string, limit = 20): Promise<SearchHit[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_global_search', { p_term: term, p_limit: limit })
  if (error) throw new Error(error.message)
  return (data ?? []) as SearchHit[]
}

export interface BirthdayRow {
  kind: 'student' | 'staff'
  id: string
  full_name: string
  dob: string
  /** The age they are turning on that birthday. */
  turning: number
  birthday: string
  /** 0 is today. Never negative — a past birthday rolls to next year. */
  days_away: number
  class_name: string
  detail: string
  phone: string | null
}

export async function getBirthdays(withinDays = 0): Promise<BirthdayRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_birthdays', { p_within_days: withinDays })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as BirthdayRow),
    turning: Number(r.turning ?? 0),
    days_away: Number(r.days_away ?? 0),
  }))
}

// ---- Teacher remarks and position holders --------------------------------

export interface ExamRemarkRow {
  student_id: string
  student_name: string
  gr_no: string | null
  roll_no: string | null
  section_name: string | null
  remark: string | null
  remark_by_name: string
  updated_at: string | null
  percentage: number | null
  grade: string | null
  class_position: number | null
}

/** Every child in the class, remark or not — a teacher needs to see who is left. */
export async function listExamRemarks(
  examTermId: string, classId: string,
): Promise<ExamRemarkRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_exam_remarks', {
    p_exam_term_id: examTermId, p_class_id: classId,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as ExamRemarkRow),
    percentage: r.percentage == null ? null : Number(r.percentage),
    class_position: r.class_position == null ? null : Number(r.class_position),
  }))
}

/** Blank removes the remark rather than storing an empty string. */
export async function setExamRemark(
  examTermId: string, studentId: string, remark: string,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_exam_remark', {
    p_exam_term_id: examTermId, p_student_id: studentId, p_remark: remark,
  })
  if (error) throw new Error(error.message)
}

export interface PositionHolder {
  class_id: string
  class_name: string
  level_order: number
  class_position: number
  student_id: string
  student_name: string
  gr_no: string | null
  roll_no: string | null
  section_name: string | null
  total_marks: number | null
  total_max: number | null
  percentage: number | null
  grade: string | null
  /** Result held back over unpaid fees — worth knowing BEFORE the announcement. */
  withheld: boolean
  remark: string | null
  /** How many children share this position. 1 means outright. */
  tied_with: number
}

/**
 * Top N in every class for one exam term.
 *
 * Ties are preserved as they are on the result card: two children on 90% are
 * both first and the next is third. Handing one of them the prize on an
 * unstated tie-break is not something software should do quietly.
 */
export async function getPositionHolders(
  examTermId: string, top = 3,
): Promise<PositionHolder[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_position_holders', {
    p_exam_term_id: examTermId, p_top: top,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as PositionHolder),
    level_order: Number(r.level_order ?? 0),
    class_position: Number(r.class_position ?? 0),
    total_marks: r.total_marks == null ? null : Number(r.total_marks),
    total_max: r.total_max == null ? null : Number(r.total_max),
    percentage: r.percentage == null ? null : Number(r.percentage),
    tied_with: Number(r.tied_with ?? 1),
  }))
}

// ---- Mark and attendance corrections -------------------------------------

export interface MarkCorrection {
  changed_at: string
  kind: 'Exam' | 'Class test'
  student_name: string
  gr_no: string | null
  class_name: string | null
  section_name: string | null
  subject_name: string | null
  paper: string | null
  /** What the mark was before it was changed. */
  was: number | null
  now_is: number | null
  max_marks: number | null
  is_absent: boolean
  reason: string | null
  changed_by: string
  is_locked: boolean
}

/**
 * Every mark changed since it was first entered — what it was, what it is, who
 * changed it and why.
 *
 * mark_entries has recorded `corrected_from` all along and NOTHING ever read
 * it, so a parent disputing "my son got 45, you have written 40" could not be
 * answered from data the database already held. Owner and principal only: the
 * person most likely to want this hidden is the person who changed the mark.
 */
export async function getMarkCorrections(
  from: string | null = null, to: string | null = null,
): Promise<MarkCorrection[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_mark_corrections', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as MarkCorrection),
    was: r.was == null ? null : Number(r.was),
    now_is: r.now_is == null ? null : Number(r.now_is),
    max_marks: r.max_marks == null ? null : Number(r.max_marks),
  }))
}

export interface AttendanceCorrection {
  changed_at: string
  attendance_date: string
  student_name: string
  gr_no: string | null
  class_name: string | null
  section_name: string | null
  was: string | null
  now_is: string | null
  reason: string | null
  changed_by: string
}

export async function getAttendanceCorrections(
  from: string | null = null, to: string | null = null,
): Promise<AttendanceCorrection[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_attendance_corrections', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return (data ?? []) as AttendanceCorrection[]
}

// ---- Admission enquiries (their "Admission Inquiries") --------------------

export type EnquiryStatus = 'new' | 'contacted' | 'visited' | 'admitted' | 'lost'
export type EnquirySource =
  'walk_in' | 'phone' | 'referral' | 'banner' | 'social_media' | 'other'

export interface EnquiryRow {
  id: string
  enquiry_no: number
  child_name: string
  father_name: string | null
  phone: string
  whatsapp: string | null
  class_name: string | null
  class_wanted: string | null
  session_name: string | null
  source: EnquirySource
  status: EnquiryStatus
  follow_up_on: string | null
  /** 0 unless the enquiry is open and its follow-up date has passed. */
  days_overdue: number
  contacts: number
  last_contact_at: string | null
  last_outcome: string | null
  lost_reason: string | null
  notes: string | null
  created_at: string
  created_by_name: string
  admitted_student_id: string | null
  admitted_gr_no: string | null
  /** Full match count, not the page — see fn_enquiry_list. */
  total_count: number
}

export interface EnquiryListArgs {
  status?: EnquiryStatus | null
  from?: string | null
  to?: string | null
  search?: string | null
  /** Only open enquiries whose follow-up date is today or earlier. */
  dueOnly?: boolean
  limit?: number
  offset?: number
}

/**
 * Ordered by who has waited longest, not by who called most recently —
 * newest-first buries the parent who has been waiting nine days.
 */
export async function listEnquiries(a: EnquiryListArgs = {}): Promise<EnquiryRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enquiry_list', {
    p_status: a.status ?? null,
    p_from: a.from ?? null,
    p_to: a.to ?? null,
    p_search: a.search ?? null,
    p_due_only: a.dueOnly ?? false,
    p_limit: a.limit ?? 200,
    p_offset: a.offset ?? 0,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as EnquiryRow),
    enquiry_no: Number(r.enquiry_no ?? 0),
    days_overdue: Number(r.days_overdue ?? 0),
    contacts: Number(r.contacts ?? 0),
    total_count: Number(r.total_count ?? 0),
  }))
}

export interface EnquiryContact {
  id: string
  contacted_at: string
  outcome: string
  note: string | null
  by_name: string
}

export async function getEnquiryContacts(enquiryId: string): Promise<EnquiryContact[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enquiry_contacts', { p_enquiry_id: enquiryId })
  if (error) throw new Error(error.message)
  return (data ?? []) as EnquiryContact[]
}

export interface NewEnquiry {
  child_name: string
  phone: string
  father_name?: string | null
  father_cnic?: string | null
  whatsapp?: string | null
  address?: string | null
  dob?: string | null
  gender?: string | null
  session_id?: string | null
  class_id?: string | null
  class_wanted?: string | null
  source?: EnquirySource
  source_note?: string | null
  follow_up_on?: string | null
  notes?: string | null
}

export interface AddEnquiryResult {
  enquiry_id: string
  enquiry_no: number
  message_queued: boolean
  /**
   * Set when the same child name already exists on the same phone number. A
   * WARNING, not a rejection — the same number enquiring again is usually a
   * second child.
   */
  possible_duplicate: {
    id: string
    enquiry_no: number
    child_name: string
    status: EnquiryStatus
    created_at: string
  } | null
}

export async function addEnquiry(e: NewEnquiry): Promise<AddEnquiryResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_add_enquiry', { p: e })
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, unknown>
  return {
    enquiry_id: String(r.enquiry_id ?? ''),
    enquiry_no: Number(r.enquiry_no ?? 0),
    message_queued: Boolean(r.message_queued),
    possible_duplicate: (r.possible_duplicate ?? null) as AddEnquiryResult['possible_duplicate'],
  }
}

/** Appends to the history AND moves the next follow-up date, in one call. */
export async function logEnquiryContact(
  enquiryId: string, outcome: string, note: string | null, nextFollowUp: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_log_enquiry_contact', {
    p_enquiry_id: enquiryId, p_outcome: outcome,
    p_note: note, p_next_follow_up: nextFollowUp,
  })
  if (error) throw new Error(error.message)
}

/** 'admitted' is not settable here — use admitEnquiry, which creates the student. */
export async function setEnquiryStatus(
  enquiryId: string, status: Exclude<EnquiryStatus, 'admitted'>,
  lostReason: string | null = null, nextFollowUp: string | null = null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_enquiry_status', {
    p_enquiry_id: enquiryId, p_status: status,
    p_lost_reason: lostReason, p_next_follow_up: nextFollowUp,
  })
  if (error) throw new Error(error.message)
}

/**
 * Converts to a real admission through fn_admit_student, so the GR number,
 * family linkage and student limit behave exactly as for a walk-in. Refuses a
 * second attempt on the same enquiry.
 */
export async function admitEnquiry(
  enquiryId: string, overrides: Record<string, unknown> = {},
): Promise<Record<string, unknown>> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enquiry_admit', {
    p_enquiry_id: enquiryId, p_overrides: overrides,
  })
  if (error) throw new Error(error.message)
  return (data ?? {}) as Record<string, unknown>
}

export interface EnquirySummary {
  open: number
  due_today: number
  overdue: number
  /** Open enquiries with no follow-up date — should always be 0. */
  open_no_date: number
  this_month: number
  admitted: number
  lost: number
  decided: number
  /** null, not 0, when nothing has been decided yet. */
  conversion_rate: number | null
}

export async function getEnquirySummary(): Promise<EnquirySummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enquiry_summary')
  if (error) throw new Error(error.message)
  const r = (data ?? {}) as Record<string, unknown>
  const n = (k: string) => Number(r[k] ?? 0)
  return {
    open: n('open'), due_today: n('due_today'), overdue: n('overdue'),
    open_no_date: n('open_no_date'), this_month: n('this_month'),
    admitted: n('admitted'), lost: n('lost'), decided: n('decided'),
    conversion_rate: r.conversion_rate == null ? null : Number(r.conversion_rate),
  }
}

export interface EnquirySourceRow {
  source: EnquirySource
  enquiries: number
  admitted: number
  lost: number
  open: number
  conversion_rate: number | null
}

/** Which sources actually convert. A banner costs money; this says what it bought. */
export async function getEnquirySources(
  from: string | null = null, to: string | null = null,
): Promise<EnquirySourceRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enquiry_sources', { p_from: from, p_to: to })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    source: r.source as EnquirySource,
    enquiries: Number(r.enquiries ?? 0),
    admitted: Number(r.admitted ?? 0),
    lost: Number(r.lost ?? 0),
    open: Number(r.open ?? 0),
    conversion_rate: r.conversion_rate == null ? null : Number(r.conversion_rate),
  }))
}

// ---- Message settings (their "Automation Settings") -----------------------

export interface MessageSetting {
  template_key: string
  label: string
  body: string
  enabled: boolean
  /** Merge tags this template may use. Comes from SQL because it is a fact
   *  about the call site — {receipt} only resolves for payment_received. */
  tags: string[]
  is_default: boolean
}

/** What the school currently sends, and what each message may reference. */
export async function listMessageSettings(): Promise<MessageSetting[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_message_settings')
  if (error) throw new Error(error.message)
  return (data ?? []) as MessageSetting[]
}

/**
 * Change the wording, or switch a message type off entirely.
 *
 * A direct table write rather than an RPC: message_templates already carries an
 * owner/principal-only write policy, so the database is enforcing this whether
 * the call comes from here or anywhere else.
 */
export async function saveMessageSetting(
  templateKey: string, patch: { body?: string; enabled?: boolean },
): Promise<void> {
  const sb = requireSupabase()
  await mustWrite(
    await sb.from('message_templates').update(patch)
      .eq('template_key', templateKey).select('template_key'),
    'That message template')
}

/** Put one template's original wording back. Returns the restored text. */
export async function resetMessageTemplate(templateKey: string): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_reset_message_template', {
    p_template_key: templateKey,
  })
  if (error) throw new Error(error.message)
  return String(data ?? '')
}

/**
 * Fill merge tags with sample values so the editor can show what a parent will
 * actually receive. Mirrors fn__render_template's simple {tag} replacement —
 * deliberately not a second templating engine, just the same substitution.
 */
export function previewMessage(body: string, schoolName: string): string {
  const sample: Record<string, string> = {
    parent: 'Muhammad Aslam',
    children: 'Ahmed, Bilal',
    school: schoolName,
    date: new Date().toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' }),
    balance: '4,850',
    amount: '3,650',
    receipt: '1042',
    received_by: 'Basha Salamat',
  }
  return Object.entries(sample).reduce(
    (out, [k, v]) => out.split(`{${k}}`).join(v),
    body,
  )
}

// ---- Bulk collection ------------------------------------------------------

export interface ClassDue {
  student_id: string
  full_name: string
  gr_no: string | null
  roll_no: string | null
  father_name: string | null
  phone: string | null
  family_id: string | null
  family_head: string | null
  invoice_id: string | null
  voucher_code: string | null
  month_charge: number
  month_paid: number
  month_due: number
  /** Everything the student owes, not just this month. */
  total_due: number
  last_paid_at: string | null
}

/** The whole class and what each child owes — paid ones included, so a clerk
 *  working down a register can see they have not skipped anybody. */
export async function getClassDues(
  sessionId: string, classId: string, sectionId: string | null, periodMonth: string,
): Promise<ClassDue[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_class_dues', {
    p_session_id: sessionId, p_class_id: classId,
    p_section_id: sectionId, p_period_month: periodMonth,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    ...(r as unknown as ClassDue),
    month_charge: Number(r.month_charge ?? 0),
    month_paid: Number(r.month_paid ?? 0),
    month_due: Number(r.month_due ?? 0),
    total_due: Number(r.total_due ?? 0),
  }))
}

export interface BulkPaymentResult {
  count: number
  total: number
  receipts: { student_id: string; amount: number; receipt_no: number | null }[]
}

/**
 * Record many payments as ONE transaction.
 *
 * If any row is bad the whole batch is refused and nothing is written — a clerk
 * who cannot tell which of forty rows went through has no way to recover.
 */
export async function recordBulkPayments(
  items: { student_id: string; amount: number }[],
  method: string,
  note?: string,
  pending = false,
): Promise<BulkPaymentResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_bulk_payments', {
    p_items: items, p_method: method, p_note: note ?? null, p_pending: pending,
  })
  if (error) throw new Error(error.message)
  const d = (data ?? {}) as Record<string, unknown>
  return {
    count: Number(d.count ?? 0),
    total: Number(d.total ?? 0),
    receipts: ((d.receipts ?? []) as Record<string, unknown>[]).map((r) => ({
      student_id: String(r.student_id),
      amount: Number(r.amount ?? 0),
      receipt_no: r.receipt_no == null ? null : Number(r.receipt_no),
    })),
  }
}

/** Queue one WhatsApp reminder per FAMILY that owes, escalating on repeats. */
export async function queueClassReminders(
  sessionId: string, classId: string, sectionId: string | null,
): Promise<{ queued: number; skipped: number }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_queue_class_reminders', {
    p_session_id: sessionId, p_class_id: classId, p_section_id: sectionId,
  })
  if (error) throw new Error(error.message)
  const d = (data ?? {}) as Record<string, unknown>
  return { queued: Number(d.queued ?? 0), skipped: Number(d.skipped ?? 0) }
}

// ---- Fee operations -------------------------------------------------------

export interface FeeIncrementRow { class: string; fee_head: string; from: number; to: number }
export interface FeeIncrementResult {
  committed: boolean; effective_from: string; changes: number; rows: FeeIncrementRow[]
}

export async function feeIncrement(
  sessionId: string, classIds: string[] | null, headIds: string[] | null,
  percent: number | null, amount: number | null, effectiveFrom: string, commit: boolean,
): Promise<FeeIncrementResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_fee_increment', {
    p_session_id: sessionId, p_class_ids: classIds, p_fee_head_ids: headIds,
    p_percent: percent, p_amount: amount, p_effective_from: effectiveFrom, p_commit: commit,
  })
  if (error) throw new Error(error.message)
  return data as FeeIncrementResult
}

export interface CounterSummary {
  unpaid_invoices: number
  income_today: number
  expense_today: number
  balance_today: number
  pending_count: number
  pending_amount: number
}

/**
 * The four figures the fee counter opens on. One round trip on purpose — the
 * clerk reloads this screen all morning and the numbers have to agree with each
 * other, so they are computed together.
 */
export async function getCounterSummary(): Promise<CounterSummary> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_counter_summary')
  if (error) throw new Error(error.message)
  const d = (data ?? {}) as Record<string, unknown>
  return {
    unpaid_invoices: Number(d.unpaid_invoices ?? 0),
    income_today: Number(d.income_today ?? 0),
    expense_today: Number(d.expense_today ?? 0),
    balance_today: Number(d.balance_today ?? 0),
    pending_count: Number(d.pending_count ?? 0),
    pending_amount: Number(d.pending_amount ?? 0),
  }
}

export interface RecentPayment {
  payment_id: string
  receipt_no: number | null
  paid_at: string
  student_id: string | null
  student_name: string
  gr_no: string | null
  family_id: string | null
  parent_name: string | null
  class_name: string | null
  section_name: string | null
  /** Which months this receipt settled. Null for money held as family credit. */
  paid_for: string | null
  amount: number
  method: string
  /** Fine on the challans this receipt paid — not a share apportioned to it. */
  late_fee: number
  /** Discount on those same challans, same caveat. */
  discount: number
  note: string | null
  status: string
  received_by: string
  is_reversal: boolean
}

/** The day's receipts, newest first. Shown before anyone searches for anything. */
export async function listRecentPayments(limit = 25): Promise<RecentPayment[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_recent_payments', { p_limit: limit })
  if (error) throw new Error(error.message)
  return (data ?? []).map((r: Record<string, unknown>) => ({
    ...(r as unknown as RecentPayment),
    receipt_no: r.receipt_no == null ? null : Number(r.receipt_no),
    amount: Number(r.amount ?? 0),
    late_fee: Number(r.late_fee ?? 0),
    discount: Number(r.discount ?? 0),
  }))
}

export interface ChallanLine { description: string; amount: number; is_discount: boolean }

export interface Challan {
  invoice_id: string
  voucher_code: string | null
  status: string
  period_month: string | null
  period_label: string
  due_date: string | null
  student_id: string
  student_name: string
  gr_no: string | null
  roll_no: string | null
  father_name: string | null
  family_head: string | null
  family_cnic: string | null
  phone: string | null
  class_name: string | null
  section_name: string | null
  lines: ChallanLine[]
  fine: number
  this_month: number
  already_paid: number
  this_month_due: number
  /** Computed live, not the generation-time snapshot — see migration 0039. */
  previous_dues: number
  /** Equals student_balance(). The paper and the ledger are the same number. */
  total_payable: number
  arrears_snapshot_at_generation: number
}

function toChallan(raw: Record<string, unknown>): Challan {
  const num = (v: unknown) => Number(v ?? 0)
  return {
    ...(raw as unknown as Challan),
    lines: ((raw.lines ?? []) as Record<string, unknown>[]).map((l) => ({
      description: String(l.description ?? ''),
      amount: num(l.amount),
      is_discount: !!l.is_discount,
    })),
    fine: num(raw.fine),
    this_month: num(raw.this_month),
    already_paid: num(raw.already_paid),
    this_month_due: num(raw.this_month_due),
    previous_dues: num(raw.previous_dues),
    total_payable: num(raw.total_payable),
    arrears_snapshot_at_generation: num(raw.arrears_snapshot_at_generation),
  }
}

/** One challan, everything the paper needs. Reprintable at any time. */
export async function getChallan(invoiceId: string): Promise<Challan> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_challan', { p_invoice_id: invoiceId })
  if (error) throw new Error(error.message)
  return toChallan((data ?? {}) as Record<string, unknown>)
}

/** A whole class's challans for one month, in roll-number order. */
export async function getClassChallans(
  sessionId: string, classId: string, sectionId: string | null, periodMonth: string,
): Promise<Challan[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_challans_for_class', {
    p_session_id: sessionId, p_class_id: classId,
    p_section_id: sectionId, p_period_month: periodMonth,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map(toChallan)
}

export interface ChallanMonth { period_month: string; challans: number; unpaid: number }

/** Which months actually have challans, so the print screen offers real choices. */
export async function listChallanMonths(sessionId: string, classId: string): Promise<ChallanMonth[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_challan_months', {
    p_session_id: sessionId, p_class_id: classId,
  })
  if (error) throw new Error(error.message)
  return ((data ?? []) as Record<string, unknown>[]).map((r) => ({
    period_month: String(r.period_month),
    challans: Number(r.challans ?? 0),
    unpaid: Number(r.unpaid ?? 0),
  }))
}

export async function findByVoucher(code: string) {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_find_by_voucher', { p_code: code })
  if (error) throw new Error(error.message)
  return data as { invoice_id: string; student_id: string; student_name: string
                   family_id: string; period_month: string | null } | null
}

export async function getHeadWiseDues(sessionId: string) {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_head_wise_dues', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
  return data as { session_id: string; basis: string
                   heads: { fee_head: string; charged: number; collected: number }[] }
}

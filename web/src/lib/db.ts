import { createClient } from '@supabase/supabase-js'
import { requireSupabase } from './supabase'
import { config } from './config'

// ---- Types (hand-written; kept in sync with supabase/migrations) ----
export interface SessionRow { id: string; name: string; is_current: boolean }
export interface ClassRow { id: string; name: string; level_order: number }
export interface FeeHead {
  id: string; name: string; type: string; is_recurring: boolean; active: boolean; sort_order: number
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
    await sb.from('fee_heads').select('id, name, type, is_recurring, active, sort_order').eq('active', true).order('sort_order'),
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

export async function markAttendance(
  date: string, marks: { enrollment_id: string; status: AttendanceStatus }[],
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_mark_attendance', { p_date: date, p_marks: marks })
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
  const { error } = await sb.from('student_links').delete().eq('id', linkId)
  if (error) throw new Error(error.message)
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
      .select('id, gr_no, admission_no, full_name, father_name, mother_name, b_form, dob, gender, address, phone, whatsapp, status, admission_date, notes')
      .eq('id', studentId).single(),
  )
}

export async function updateStudent(studentId: string, patch: Partial<StudentProfile>): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('students').update(patch).eq('id', studentId)
  if (error) throw new Error(error.message)
}

export async function setStudentStatus(studentId: string, status: string, reason?: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_set_student_status', {
    p_student_id: studentId, p_status: status, p_reason: reason ?? null,
  })
  if (error) throw new Error(error.message)
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
export interface SubjectRow { id: string; name: string; class_id: string | null; sort_order: number }
export interface ExamSubjectRow {
  id: string; subject_id: string; subject_name: string; max_marks: number; pass_marks: number
  exam_date: string | null; paper_time: string | null
}
export interface ClassRosterRow {
  enrollment_id: string; student_id: string; full_name: string; father_name: string | null
  gr_no: string | null; roll_no: string | null; section_name: string | null
}
export interface MarksheetRow {
  enrollment_id: string; student_id: string; full_name: string; roll_no: string | null
  section_name: string | null; marks: number | null; is_absent: boolean; is_locked: boolean; max_marks: number
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
  subjects: { subject: string; max: number; pass: number; marks: number | null; is_absent: boolean; grade: string | null }[]
  total_marks: number; total_max: number; percentage: number | null; grade: string | null
  position: number | null; attendance_pct: number | null; withheld: boolean; balance: number
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
  return unwrap(
    await sb.from('subjects').select('id, name, class_id, sort_order').eq('class_id', classId).order('sort_order').order('name'),
  )
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
      .select('id, subject_id, max_marks, pass_marks, exam_date, paper_time, subjects(name, sort_order)')
      .eq('exam_term_id', termId).eq('class_id', classId),
  )
  return rows
    .map((r) => ({
      id: r.id, subject_id: r.subject_id, subject_name: r.subjects?.name ?? '—',
      max_marks: Number(r.max_marks), pass_marks: Number(r.pass_marks),
      exam_date: r.exam_date ?? null, paper_time: r.paper_time ?? null,
      _sort: r.subjects?.sort_order ?? 0,
    }))
    .sort((a, b) => a._sort - b._sort || a.subject_name.localeCompare(b.subject_name))
    .map(({ _sort, ...rest }) => rest)
}

export async function upsertExamSubject(
  termId: string, classId: string, subjectId: string, maxMarks: number, passMarks: number,
  examDate?: string | null, paperTime?: string | null,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('exam_subjects').upsert(
    {
      exam_term_id: termId, class_id: classId, subject_id: subjectId,
      max_marks: maxMarks, pass_marks: passMarks,
      exam_date: examDate || null, paper_time: paperTime || null,
    },
    { onConflict: 'exam_term_id,class_id,subject_id' },
  )
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
  const { error } = await sb.from('exam_subjects').delete().eq('id', id)
  if (error) throw new Error(error.message)
}

export async function getMarksheet(examSubjectId: string): Promise<MarksheetRow[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_exam_marksheet', { p_exam_subject_id: examSubjectId })
  if (error) throw new Error(error.message)
  return (data as MarksheetRow[]) ?? []
}

export async function enterMarks(
  examSubjectId: string, marks: { enrollment_id: string; marks: number | null; is_absent: boolean }[],
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enter_marks', { p_exam_subject_id: examSubjectId, p_marks: marks })
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
): Promise<MarkResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_enter_assessment_marks', { p_assessment_id: assessmentId, p_marks: marks })
  if (error) throw new Error(error.message)
  return data as MarkResult
}

export async function lockAssessment(assessmentId: string): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.rpc('fn_lock_assessment', { p_assessment_id: assessmentId })
  if (error) throw new Error(error.message)
}

export async function generateResultCards(termId: string, classId: string): Promise<number> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_generate_result_cards', { p_exam_term_id: termId, p_class_id: classId })
  if (error) throw new Error(error.message)
  return Number(data)
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
}
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
    .select('name, name_short, address, phone, email, principal_name, grade_scale, pass_percent, gr_prefix, receipt_prefix, current_session_id, geofence_enabled, geo_lat, geo_lng, geo_radius_m')
    .limit(1).maybeSingle()
  if (error) throw new Error(error.message)
  return data
}

export async function updateSchoolSettings(patch: Partial<SchoolSettings>): Promise<void> {
  const sb = requireSupabase()
  // An UPDATE, not an upsert: the settings row is created with the school, so
  // there is nothing to insert — and an upsert here could only ever write a row
  // RLS would reject anyway.
  const { error } = await sb.from('school_settings').update(patch).eq('school_id', await mySchoolId())
  if (error) throw new Error(error.message)
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
  const { error } = await sb.from('classes').update({ active }).eq('id', id)
  if (error) throw new Error(error.message)
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
  const { error } = await sb.from('profiles').update({ role }).eq('id', id)
  if (error) throw new Error(error.message)
}

export async function setProfileActive(id: string, active: boolean): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('profiles').update({ active }).eq('id', id)
  if (error) throw new Error(error.message)
}

// ---- Staff ----
export interface StaffRow {
  id: string; full_name: string; designation: string | null; employee_no: string | null
  mobile: string | null; whatsapp: string | null; cnic: string | null
  joined_on: string | null; status: string; profile_id: string | null
}
export interface StaffInput {
  full_name: string; designation?: string | null; employee_no?: string | null
  mobile?: string | null; whatsapp?: string | null; cnic?: string | null; joined_on?: string | null
}
export interface SectionTeacherRow { id: string; name: string; class_teacher_id: string | null }

export async function listStaff(): Promise<StaffRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('staff')
      .select('id, full_name, designation, employee_no, mobile, whatsapp, cnic, joined_on, status, profile_id')
      .is('deleted_at', null).order('full_name'),
  )
}

export async function createStaff(input: StaffInput): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('staff').insert({
    full_name: input.full_name, designation: input.designation || null, employee_no: input.employee_no || null,
    mobile: input.mobile || null, whatsapp: input.whatsapp || null, cnic: input.cnic || null,
    joined_on: input.joined_on || null,
  }).select('id').single()
  if (error) throw new Error(error.message)
  return (data as { id: string }).id
}

export async function updateStaff(id: string, patch: Partial<StaffInput>): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('staff').update(patch).eq('id', id)
  if (error) throw new Error(error.message)
}

export async function setStaffStatus(id: string, status: 'active' | 'inactive'): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('staff').update({ status }).eq('id', id)
  if (error) throw new Error(error.message)
}

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
  const { error } = await sb.from('sections').update({ class_teacher_id: staffId }).eq('id', sectionId)
  if (error) throw new Error(error.message)
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
  const { error } = await sb.from('teacher_assignments').delete().eq('id', id)
  if (error) throw new Error(error.message)
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

export interface CheckinCode { id: string; code: string; label: string | null; valid_from: string | null; valid_to: string | null; active: boolean }
export async function generateCheckinCode(
  label: string, validFrom: string | null, validTo: string | null, deactivateOthers = true,
): Promise<{ id: string; code: string }> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_generate_checkin_code', {
    p_label: label, p_valid_from: validFrom, p_valid_to: validTo, p_deactivate_others: deactivateOthers,
  })
  if (error) throw new Error(error.message)
  return data as { id: string; code: string }
}
export async function listCheckinCodes(): Promise<CheckinCode[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb.from('staff_checkin_codes').select('id, code, label, valid_from, valid_to, active')
      .order('created_at', { ascending: false }),
  )
}

export interface CheckInResult { status: 'ok' | 'already'; checked_at: string; attendance_status?: string }
export async function staffCheckIn(
  code: string, lat: number | null, lng: number | null, device: string | null,
): Promise<CheckInResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_staff_check_in', {
    p_code: code, p_lat: lat, p_lng: lng, p_device: device,
  })
  if (error) throw new Error(error.message)
  return data as CheckInResult
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

  // Function not deployed / unreachable → create the login directly with a
  // throwaway client (a separate storageKey + no session persistence means the
  // principal stays logged in). The handle_new_user trigger makes the profile;
  // we then set the role as the principal (who passes the role guard).
  const tmp = createClient(config.supabaseUrl!, config.supabaseAnonKey!, {
    auth: { persistSession: false, autoRefreshToken: false, storageKey: 'provision-teacher' },
  })
  const { data: su, error: suErr } = await tmp.auth.signUp({
    email, password: input.password, options: { data: { full_name: fullName || email.split('@')[0] } },
  })
  if (suErr) throw new Error(suErr.message)
  const newId = su.user?.id
  if (!newId) throw new Error('Could not create the login.')

  await updateProfileRole(newId, role)

  // If the project still requires email confirmation, the teacher can't sign in
  // with just the password — tell the principal exactly what to switch off.
  if (!su.session && !su.user?.email_confirmed_at) {
    throw new Error(
      'Login created, but this Supabase project requires email confirmation, so the teacher can’t sign in yet. ' +
      'In Supabase → Authentication → Providers → Email, turn OFF “Confirm email” (one-time), then this login will work. ' +
      '(Or deploy the create-teacher function once and it’s handled automatically.)',
    )
  }
  return { id: newId, email, role }
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
export interface IssueCertResult { id: string; serial_no: number; cert_type: string; issued_on: string }
export interface CertificateRow {
  id: string; cert_type: string; serial_no: number; issued_on: string
  student_name: string | null; gr_no: string | null; data: Record<string, any>
}

export async function issueCertificate(
  certType: string, studentId: string, data: Record<string, any>,
): Promise<IssueCertResult> {
  const sb = requireSupabase()
  const { data: res, error } = await sb.rpc('fn_issue_certificate', {
    p_cert_type: certType, p_student_id: studentId, p_data: data,
  })
  if (error) throw new Error(error.message)
  return res as IssueCertResult
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

export async function listCertificates(limit = 50): Promise<CertificateRow[]> {
  const sb = requireSupabase()
  const rows = unwrap<Record<string, any>[]>(
    await sb.from('certificates')
      .select('id, cert_type, serial_no, issued_on, data, students(full_name, gr_no)')
      .order('created_at', { ascending: false }).limit(limit),
  )
  return rows.map((r) => ({
    id: r.id, cert_type: r.cert_type, serial_no: Number(r.serial_no), issued_on: r.issued_on,
    student_name: r.students?.full_name ?? r.data?.student_name ?? null,
    gr_no: r.students?.gr_no ?? r.data?.gr_no ?? null,
    data: r.data ?? {},
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

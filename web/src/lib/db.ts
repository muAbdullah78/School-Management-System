import { requireSupabase } from './supabase'

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
}
export interface PaymentRow {
  id: string; amount: number; method: string; receipt_no: number | null
  created_at: string; note: string | null; reversal_of: string | null
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
  return unwrap(
    await sb
      .from('students')
      .select('id, gr_no, full_name, father_name')
      .or(`full_name.ilike.%${term}%,gr_no.ilike.%${term}%`)
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
      .select('invoice_id, period_month, status, due_date, arrears_brought_forward, fine, charge, allocated')
      .eq('student_id', studentId)
      .order('period_month', { ascending: false }),
  )
}

export async function getStudentPayments(studentId: string): Promise<PaymentRow[]> {
  const sb = requireSupabase()
  return unwrap(
    await sb
      .from('payments')
      .select('id, amount, method, receipt_no, created_at, note, reversal_of')
      .eq('student_id', studentId)
      .order('created_at', { ascending: false }),
  )
}

export async function recordPayment(
  studentId: string, amount: number, method: string, note?: string,
): Promise<RecordPaymentResult> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_record_payment', {
    p_student_id: studentId, p_amount: amount, p_method: method, p_note: note ?? null,
  })
  if (error) throw new Error(error.message)
  return data as RecordPaymentResult
}

export async function reversePayment(paymentId: string, reason: string): Promise<string> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_reverse_payment', { p_payment_id: paymentId, p_reason: reason })
  if (error) throw new Error(error.message)
  return data as string
}

export async function getDefaulters(sessionId: string): Promise<Defaulter[]> {
  const sb = requireSupabase()
  const { data, error } = await sb.rpc('fn_defaulters', { p_session_id: sessionId })
  if (error) throw new Error(error.message)
  return (data as Defaulter[]) ?? []
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
  admission_no?: string; admission_date?: string; notes?: string
  session_id: string; class_id: string; section_id?: string | null; roll_no?: string; gr_no?: string
  guardian?: { name: string; relation?: string; phone?: string; whatsapp?: string }
}
export interface AdmitResult { student_id: string; enrollment_id: string; gr_no: string; roll_no: string }

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

export async function listStudents(term: string): Promise<StudentRow[]> {
  const sb = requireSupabase()
  const t = term.trim()
  let q = sb.from('students').select('id, gr_no, full_name, father_name').is('deleted_at', null)
  if (t) q = q.or(`full_name.ilike.%${t}%,gr_no.ilike.%${t}%`)
  return unwrap(await q.order('full_name').limit(50))
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
      .select('id, subject_id, max_marks, pass_marks, subjects(name, sort_order)')
      .eq('exam_term_id', termId).eq('class_id', classId),
  )
  return rows
    .map((r) => ({
      id: r.id, subject_id: r.subject_id, subject_name: r.subjects?.name ?? '—',
      max_marks: Number(r.max_marks), pass_marks: Number(r.pass_marks),
      _sort: r.subjects?.sort_order ?? 0,
    }))
    .sort((a, b) => a._sort - b._sort || a.subject_name.localeCompare(b.subject_name))
    .map(({ _sort, ...rest }) => rest)
}

export async function upsertExamSubject(
  termId: string, classId: string, subjectId: string, maxMarks: number, passMarks: number,
): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('exam_subjects').upsert(
    { exam_term_id: termId, class_id: classId, subject_id: subjectId, max_marks: maxMarks, pass_marks: passMarks },
    { onConflict: 'exam_term_id,class_id,subject_id' },
  )
  if (error) throw new Error(error.message)
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
      .select('id, enrollment_id, student_id, total_marks, total_max, percentage, grade, position, attendance_pct, version, frozen, students(full_name, gr_no), enrollments!inner(class_id, roll_no)')
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
    })
  }
  return out.sort((a, b) => (a.position ?? 1e9) - (b.position ?? 1e9))
}

// ---- Settings / school setup ----
export interface SchoolSettings {
  name: string; name_short: string | null; address: string | null; phone: string | null
  email: string | null; principal_name: string | null; grade_scale: string; pass_percent: number
  gr_prefix: string | null; receipt_prefix: string | null; current_session_id: string | null
}
export interface SessionFull {
  id: string; name: string; starts_on: string | null; ends_on: string | null
  is_current: boolean; is_closed: boolean
}
export interface ClassFull { id: string; name: string; level_order: number; active: boolean }
export interface ProfileRow { id: string; full_name: string | null; role: string; active: boolean }

export async function getSchoolSettings(): Promise<SchoolSettings | null> {
  const sb = requireSupabase()
  const { data, error } = await sb.from('school_settings')
    .select('name, name_short, address, phone, email, principal_name, grade_scale, pass_percent, gr_prefix, receipt_prefix, current_session_id')
    .eq('id', 1).maybeSingle()
  if (error) throw new Error(error.message)
  return data
}

export async function updateSchoolSettings(patch: Partial<SchoolSettings>): Promise<void> {
  const sb = requireSupabase()
  const { error } = await sb.from('school_settings').upsert({ id: 1, ...patch }, { onConflict: 'id' })
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
  return unwrap(await sb.from('profiles').select('id, full_name, role, active').order('full_name'))
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

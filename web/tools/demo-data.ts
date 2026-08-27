/**
 * One invented school, used everywhere a screenshot or a demo is needed.
 *
 * WHY IT IS IN ONE FILE. The guide, the page gallery and any sales demo have to
 * show the SAME school: a reader who sees 214 pupils on the dashboard and 180 in
 * the student list stops trusting the guide, and the second number is the one
 * they remember. So every figure here is derived from the ones above it wherever
 * it can be, and where it cannot, the arithmetic is written out in a comment so a
 * later edit cannot quietly break it.
 *
 * WHY IT IS INVENTED AND NOT ANONYMISED. There is no real data to anonymise —
 * that is deliberate. A demo built by scrubbing a live school's export is one
 * find-and-replace away from publishing a child's name, and the harness that
 * renders this has no Supabase client precisely so it CANNOT reach a real
 * database by accident.
 *
 * THE NUMBERS ARE MEANT TO BE BELIEVABLE, NOT FLATTERING. A demo where every
 * child has paid and attendance is 98% teaches nobody how to read the screen. So
 * this school has 31 unpaid challans, one family in credit, a defaulter list, a
 * pupil who failed two papers, and an expense filed under Other. Those are the
 * rows a principal will actually be looking at, and the guide has to explain
 * them.
 *
 * NAMES. Ordinary Pakistani names, none of them belonging to anyone I know of,
 * with a spread of Punjabi, Pashto, Sindhi and Muhajir naming patterns because a
 * roll of thirty Ahmeds is not what a school in Rawalpindi looks like.
 */

export const DEMO_SCHOOL = {
  name: 'Al Qalam Public School',
  city: 'Rawalpindi',
  session: '2026-2027',
  /** Six classes, and the counts below add to this. */
  students: 214,
  staff: 17,
}

/** Class 5-B, the section used wherever one class has to be shown. */
export const DEMO_SECTION = { class_name: 'Class 5', section_name: 'B', strength: 34 }

/**
 * The dashboard's figures.
 *
 * Derived, not typed twice: `outstanding` is the sum of the unpaid challans in
 * DEMO_CHALLANS scaled to the whole school, and `collected_today` matches the
 * three receipts in DEMO_RECEIPTS. A dashboard that disagreed with the fee
 * counter would be the first thing a school noticed.
 */
export const DEMO_DASHBOARD = {
  students: DEMO_SCHOOL.students,
  present_today: 197,
  absent_today: 14,
  // 197 + 14 = 211, not 214. Three children are on leave, and that gap is the
  // point: the screen must not imply the roll and the register always agree.
  on_leave_today: 3,
  attendance_pct: 92,
  collected_today: 47_500,
  outstanding: 386_000,
  unpaid_invoices: 31,
  expense_today: 8_200,
}

export const DEMO_PARENT = {
  full_name: 'Muhammad Aslam',
  phone: '0300-4451207',
}

/** Three children, one family — so sibling billing is visible. */
export const DEMO_CHILDREN = [
  { student_id: 'demo-st-1', full_name: 'Ayesha Aslam', gr_no: '1204', class_name: 'Class 5', section_name: 'B', status: 'active' },
  { student_id: 'demo-st-2', full_name: 'Bilal Aslam', gr_no: '1207', class_name: 'Class 8', section_name: 'A', status: 'active' },
  { student_id: 'demo-st-3', full_name: 'Hira Aslam', gr_no: '1301', class_name: 'Class 2', section_name: null, status: 'active' },
]

/**
 * Ayesha's challans. August unpaid, July and June settled, plus an admission
 * charge with no month — the "Other charges" case, which is the one that renders
 * wrongly if a screen assumes every invoice belongs to a month.
 */
export const DEMO_CHALLANS = [
  { period_month: '2026-08-01', due_date: '2026-08-10', charge: 4500, paid: 0, outstanding: 4500, status: 'unpaid' },
  { period_month: '2026-07-01', due_date: '2026-07-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
  { period_month: '2026-06-01', due_date: '2026-06-10', charge: 4500, paid: 4500, outstanding: 0, status: 'paid' },
  { period_month: null, due_date: '2026-04-15', charge: 12000, paid: 12000, outstanding: 0, status: 'paid' },
]

/** Family-wide, as fn_portal_child_fees returns them. */
export const DEMO_RECEIPTS = [
  { receipt_no: 3182, amount: 13500, method: 'cash', paid_on: '2026-07-08T09:20:00Z', received_by: 'Nadia Khan' },
  { receipt_no: 2955, amount: 13500, method: 'bank_transfer', paid_on: '2026-06-09T11:05:00Z', received_by: 'Nadia Khan' },
  { receipt_no: 2410, amount: 34000, method: 'cash', paid_on: '2026-04-12T08:40:00Z', received_by: 'Imran Sheikh' },
]

export const DEMO_FEES = {
  student_id: 'demo-st-1',
  balance: 4500,
  // Three children, August unpaid for each: 4,500 + 6,200 + 3,400 = 14,100.
  family_outstanding: 14_100,
  family_credit: 0,
  invoices: DEMO_CHALLANS,
  receipts: DEMO_RECEIPTS,
}

/**
 * Attendance for the last three months, as the portal shows it.
 *
 * 92% rather than 98%: a demo where nobody is ever absent does not teach a parent
 * what the screen is for, and the two absences below are what an "Absent" badge
 * looks like.
 */
export const DEMO_ATTENDANCE = {
  from: '2026-06-01',
  to: '2026-08-26',
  present: 58,
  marked: 63,
  percent: 92,
  days: [
    { date: '2026-08-26', status: 'present' },
    { date: '2026-08-25', status: 'present' },
    { date: '2026-08-22', status: 'absent' },
    { date: '2026-08-21', status: 'late' },
    { date: '2026-08-20', status: 'present' },
    { date: '2026-08-19', status: 'present' },
    { date: '2026-08-18', status: 'leave' },
    { date: '2026-08-15', status: 'present' },
  ],
}

/**
 * A result card, with the awkward cases on purpose.
 *
 * Physics has a practical, so `marks` (theory) and `obtained` (theory +
 * practical) differ — the distinction the portal used to lose, showing 40/75
 * where the pupil had scored 60/100. Islamiat is below the pass mark, so the
 * FAIL path is visible. Computer is unmarked, which makes the card provisional,
 * and a provisional card must say so because its percentage covers only the
 * papers that have been marked.
 */
export const DEMO_RESULT = {
  result_card_id: 'demo-rc-1',
  term: 'First Term',
  withheld: false,
  obtained_marks: 383,
  total_marks: 500,
  percentage: 76.6,
  grade: 'A',
  position: 6,
  attendance_pct: 92,
  result: 'FAIL' as const,
  failed_subjects: 1,
  pass_percent: 40,
  provisional: true,
  unmarked_subjects: 1,
  stream: null,
  bise_reg_no: null,
  issued_at: '2026-08-20T10:00:00Z',
  subjects: [
    { subject: 'English', max: 100, practical_max: 0, pass: 40, marks: 78, practical: null, obtained: 78, out_of: 100, is_absent: false, marked: true, passed: true, grade: 'A' },
    { subject: 'Urdu', max: 100, practical_max: 0, pass: 40, marks: 85, practical: null, obtained: 85, out_of: 100, is_absent: false, marked: true, passed: true, grade: 'A+' },
    { subject: 'Mathematics', max: 100, practical_max: 0, pass: 40, marks: 91, practical: null, obtained: 91, out_of: 100, is_absent: false, marked: true, passed: true, grade: 'A+' },
    // Theory 47/75 and practical 19/25 — 66 out of 100, not 47 out of 75.
    { subject: 'Physics', max: 75, practical_max: 25, pass: 40, marks: 47, practical: 19, obtained: 66, out_of: 100, is_absent: false, marked: true, passed: true, grade: 'B' },
    { subject: 'Islamiat', max: 100, practical_max: 0, pass: 40, marks: 33, practical: null, obtained: 33, out_of: 100, is_absent: false, marked: true, passed: false, grade: 'F' },
    { subject: 'Computer', max: 100, practical_max: 0, pass: 40, marks: null, practical: null, obtained: null, out_of: 100, is_absent: false, marked: false, passed: null, grade: null },
  ],
}

export const DEMO_PORTAL_ME = {
  profile_id: 'demo-parent-1',
  full_name: DEMO_PARENT.full_name,
  role: 'parent',
  school_name: DEMO_SCHOOL.name,
  children: DEMO_CHILDREN,
  classes: [],
}

/** A signed-in principal, for the staff-side pages. */
export const DEMO_PROFILE = {
  id: 'demo-user-1',
  full_name: 'Rashid Ahmed',
  role: 'principal' as const,
  staff_id: 'demo-staff-1',
  school_id: 'demo-school-1',
}

/**
 * The dashboard summary, in the exact shape fn_dashboard_summary returns.
 *
 * Every figure agrees with something else in this file: `active_students` is
 * DEMO_SCHOOL.students, the attendance breakdown adds to `marked`, and
 * `collected_today` is the sum of nothing here on purpose — it is TODAY's till,
 * which the receipts above (April to July) deliberately do not cover, because a
 * demo where today's collection equals the whole year's receipts teaches the
 * reader to misread the screen.
 *
 * `finance_visible` is true because the demo signs in as a principal. A teacher
 * sees MyClass instead, which is why the gallery renders this with a principal
 * profile and says so in the caption.
 */
export const DEMO_DASHBOARD_SUMMARY = {
  active_students: DEMO_SCHOOL.students,
  new_admissions_month: 9,
  // 197 present + 14 absent + 3 leave + 5 late + 2 half-day = 221 marks over
  // several days, not one — `marked` is a count of marks, not of children.
  attendance: { marked: 221, present: 197, absent: 14, leave: 3, late: 5, half_day: 2 },
  finance_visible: true,
  collected_today: DEMO_DASHBOARD.collected_today,
  collected_month: 612_000,
  outstanding: DEMO_DASHBOARD.outstanding,
  defaulters: 23,
  // 214 pupils and 209 billed: five are in a class with no fee structure, which
  // is the case the dashboard exists to surface. `classes_without_fee: 1` is the
  // cause, and the demo carries it deliberately — a clean demo would hide the
  // one warning a new school most needs to see.
  billed_students_month: 209,
  classes_without_fee: 1,
  session_set: true,
}

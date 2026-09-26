/**
 * The rebuilt Exams & Results (0152) in the live preview: every tab with a
 * real-looking Class 9 (Science and Arts, sections A and B, a practical paper),
 * the term at a glance, and a subject teacher who marks only their section.
 */
import type { Scene } from './scenes'
import type { Profile } from '@/auth/AuthProvider'
import { ExamsPage } from '@/pages/exams/ExamsPage'
import { DEMO_PROFILE, DEMO_SCHOOL } from '../demo-data'

const OWNER: Profile = { ...DEMO_PROFILE, role: 'owner' }
const SUBJECT_TEACHER: Profile = { ...DEMO_PROFILE, role: 'subject_teacher', full_name: 'Bilal Ahmed', staff_id: 'st-bilal' }
const CLASS_TEACHER: Profile = { ...DEMO_PROFILE, role: 'class_teacher', full_name: 'Sidra Batool', staff_id: 'st-sidra' }
const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, is_closed: false, starts_on: '2026-04-01', ends_on: '2027-03-31' }
const SEED_SESSION: [readonly unknown[], unknown] = [['currentSession'], SESSION]

const TERMS = [
  { id: 'term1', name: 'First Term', term_type: 'first', starts_on: '2026-09-14', ends_on: '2026-09-26', result_withheld_for_defaulters: true },
  { id: 'term2', name: 'Mid Term', term_type: 'mid', starts_on: null, ends_on: null, result_withheld_for_defaulters: false },
]
const CLASSES = [
  { id: 'c8', name: 'Class 8', level_order: 80, active: true },
  { id: 'c9', name: 'Class 9', level_order: 90, active: true },
  { id: 'c10', name: 'Class 10', level_order: 100, active: true },
]
const SUBJECTS = [
  { id: 's-phy', name: 'Physics', class_id: 'c9', sort_order: 1, stream: 'Science', is_practical: true },
  { id: 's-bio', name: 'Biology', class_id: 'c9', sort_order: 2, stream: 'Science', is_practical: true },
  { id: 's-civ', name: 'Civics', class_id: 'c9', sort_order: 3, stream: 'Arts', is_practical: false },
  { id: 's-eng', name: 'English', class_id: 'c9', sort_order: 4, stream: null, is_practical: false },
  { id: 's-mat', name: 'Maths', class_id: 'c9', sort_order: 5, stream: null, is_practical: false },
  { id: 's-urd', name: 'Urdu', class_id: 'c9', sort_order: 6, stream: null, is_practical: false },
]
const paper = (id: string, sid: string, max: number, pmax: number, date: string | null) => {
  const s = SUBJECTS.find((x) => x.id === sid)!
  return {
    id, subject_id: sid, max_marks: max, pass_marks: Math.ceil(((max + pmax) * 33) / 100), practical_max: pmax,
    exam_date: date, paper_time: date ? '9:00 AM' : null,
    subjects: { name: s.name, sort_order: s.sort_order, stream: s.stream, is_practical: s.is_practical },
  }
}
const PAPERS = [
  paper('es-phy', 's-phy', 75, 25, '2026-09-15'),
  paper('es-eng', 's-eng', 100, 0, '2026-09-16'),
  paper('es-mat', 's-mat', 100, 0, '2026-09-17'),
  paper('es-urd', 's-urd', 100, 0, null),
]
const PROGRESS = [
  { exam_subject_id: 'es-phy', section_id: 'c9-a', pupils: 3, entered: 3, absent: 0, locked: 0 },
  { exam_subject_id: 'es-phy', section_id: 'c9-b', pupils: 2, entered: 1, absent: 0, locked: 0 },
  { exam_subject_id: 'es-eng', section_id: 'c9-a', pupils: 4, entered: 4, absent: 1, locked: 0 },
  { exam_subject_id: 'es-eng', section_id: 'c9-b', pupils: 4, entered: 4, absent: 0, locked: 0 },
  { exam_subject_id: 'es-mat', section_id: 'c9-a', pupils: 4, entered: 2, absent: 0, locked: 0 },
  { exam_subject_id: 'es-mat', section_id: 'c9-b', pupils: 4, entered: 0, absent: 0, locked: 0 },
  { exam_subject_id: 'es-urd', section_id: 'c9-a', pupils: 4, entered: 0, absent: 0, locked: 0 },
  { exam_subject_id: 'es-urd', section_id: 'c9-b', pupils: 4, entered: 0, absent: 0, locked: 0 },
]
const OVERVIEW = [
  { class_id: 'c8', class_name: 'Class 8', level_order: 80, papers: 6, pupils: 32, marks_expected: 192, marks_entered: 192, cards: 32, released: 32, older_released: 0, generated_at: '2026-09-28T09:00:00Z', out_of_date: 0 },
  { class_id: 'c9', class_name: 'Class 9', level_order: 90, papers: 4, pupils: 8, marks_expected: 29, marks_entered: 18, cards: 0, released: 0, older_released: 0, generated_at: null, out_of_date: 0 },
  { class_id: 'c10', class_name: 'Class 10', level_order: 100, papers: 5, pupils: 27, marks_expected: 135, marks_entered: 135, cards: 27, released: 0, older_released: 0, generated_at: '2026-09-27T12:00:00Z', out_of_date: 2 },
]
const PUPILS = [
  ['Ahmed Raza', 'A', 'Science'], ['Fatima Noor', 'A', 'Science'], ['Hassan Ali', 'A', 'Arts'], ['Mehwish Tariq', 'A', 'Science'],
  ['Zainab Iqbal', 'B', 'Science'], ['Usman Khalid', 'B', 'Arts'], ['Ayesha Siddiqui', 'B', 'Science'], ['Bilal Hussain', 'B', 'Arts'],
].map(([n, sec, st], i) => ({
  enrollment_id: `en${i}`, student_id: `st${i}`, full_name: n, father_name: ['Raza Ahmed', 'Noor Muhammad', 'Ali Akbar', 'Tariq Mehmood', 'Iqbal Hussain', 'Khalid Mahmood', 'Imran Siddiqui', 'Hussain Shah'][i],
  gr_no: `GR ${1400 + i}`, roll_no: String(i + 1), section_name: sec, section_id: `c9-${sec.toLowerCase()}`, stream: st,
}))
const PHYSICS_SHEET = PUPILS.filter((p) => p.stream === 'Science').map((p, i) => ({
  enrollment_id: p.enrollment_id, student_id: p.student_id, full_name: p.full_name, roll_no: p.roll_no,
  section_name: p.section_name, section_id: p.section_id, max_marks: 75, practical_max: 25,
  marks: i === 4 ? null : [61, 48, 22, 70, null][i], practical_marks: i === 4 ? null : [22, 19, 11, 24, null][i],
  is_absent: false, is_locked: false,
}))

// Result cards for Class 8 (released) at the class screen.
const cardFor = (p: typeof PUPILS[number], i: number) => {
  const subjects = [
    { subject: 'English', max: 100, practical_max: 0, pass: 33, marks: 78 - i * 6, practical: null },
    { subject: 'Maths', max: 100, practical_max: 0, pass: 33, marks: 91 - i * 9, practical: null },
    { subject: 'Urdu', max: 100, practical_max: 0, pass: 33, marks: 70 - i * 4, practical: null },
    { subject: 'Science', max: 75, practical_max: 25, pass: 33, marks: 60 - i * 5, practical: 22 - i },
  ].map((s) => {
    const obtained = (s.marks ?? 0) + (s.practical ?? 0)
    const outOf = s.max + s.practical_max
    return { ...s, obtained, out_of: outOf, is_absent: false, marked: true, passed: obtained >= s.pass,
      grade: obtained / outOf >= 0.8 ? 'A+' : obtained / outOf >= 0.7 ? 'A' : obtained / outOf >= 0.6 ? 'B' : obtained / outOf >= 0.5 ? 'C' : obtained / outOf >= 0.33 ? 'D' : 'F' }
  })
  const total = subjects.reduce((a, s) => a + s.obtained, 0)
  const pct = Math.round((10000 * total) / 400) / 100
  const failed = subjects.filter((s) => !s.passed).length
  return {
    id: `rc${i}`, enrollment_id: p.enrollment_id, student_id: p.student_id, total_marks: total, total_max: 400,
    percentage: pct, grade: pct >= 80 ? 'A+' : pct >= 70 ? 'A' : pct >= 60 ? 'B' : pct >= 50 ? 'C' : pct >= 33 ? 'D' : 'F',
    position: i + 1, attendance_pct: 96 - i * 2, version: 1, published_at: i < 6 ? '2026-09-29T08:00:00Z' : null,
    frozen: {
      subjects, total_marks: total, total_max: 400, percentage: pct, grade: null, position: i + 1,
      attendance_pct: 96 - i * 2, result: failed ? 'FAIL' : 'PASS', failed_subjects: failed, pass_percent: 33,
      provisional: false, unmarked_subjects: 0, withheld: i === 5, generated_at: '2026-09-28T09:00:00Z', version: 1,
      stream: null, grade_scale: 'letter',
    },
    students: { full_name: p.full_name, gr_no: p.gr_no, father_name: p.father_name },
    enrollments: { class_id: 'c8', roll_no: p.roll_no, sections: { name: p.section_name } },
  }
}
const CARDS = PUPILS.map(cardFor)
const REMARKS = PUPILS.map((p, i) => ({
  student_id: p.student_id, student_name: p.full_name, gr_no: p.gr_no, roll_no: p.roll_no, section_name: p.section_name,
  remark: i < 3 ? ['Excellent result. Keep up the hard work.', 'Works well and is keen to learn.', ''][i] || null : null,
  remark_by_name: 'Sidra Batool', updated_at: null, percentage: CARDS[i].percentage, grade: CARDS[i].grade,
  class_position: CARDS[i].position,
}))
const HOLDERS = ['Class 8', 'Class 9', 'Class 10'].flatMap((cn, ci) => [0, 1, 2].map((k) => ({
  class_id: `c${8 + ci}`, class_name: cn, level_order: 80 + ci * 10, class_position: k === 2 && ci === 1 ? 2 : k + 1,
  student_id: `h${ci}${k}`, student_name: PUPILS[(ci * 3 + k) % 8].full_name, gr_no: null, roll_no: null,
  section_name: k % 2 ? 'B' : 'A', total_marks: 380 - k * 12, total_max: 400, percentage: 95 - k * 3 - ci, grade: 'A+',
  withheld: ci === 2 && k === 1, remark: k === 0 ? 'Excellent result. Keep up the hard work.' : null,
  tied_with: k >= 1 && ci === 1 ? 2 : 1,
})))
const TEACHING = [
  { class_id: 'c9', class_name: 'Class 9', level_order: 90, section_id: 'c9-a', section_name: 'A', is_class_teacher: false, subject_id: 's-phy', subject_name: 'Physics' },
]
const CT_TEACHING = [
  { class_id: 'c8', class_name: 'Class 8', level_order: 80, section_id: null, section_name: null, is_class_teacher: true, subject_id: null, subject_name: null },
]

const base = {
  'table:exam_terms': TERMS, 'table:classes': CLASSES, 'table:subjects': SUBJECTS,
  'table:exam_subjects': PAPERS, 'table:enrollments': PUPILS.map((p) => ({
    id: p.enrollment_id, student_id: p.student_id, roll_no: p.roll_no, stream: p.stream,
    students: { full_name: p.full_name, father_name: p.father_name, gr_no: p.gr_no }, sections: { name: p.section_name, sort_order: p.section_name === 'A' ? 1 : 2 },
  })),
  fn_exam_paper_progress: PROGRESS, fn_exam_term_overview: OVERVIEW,
  fn_exam_marksheet: PHYSICS_SHEET, fn_result_readiness: [],
  'table:result_cards': CARDS, fn_exam_remarks: REMARKS, fn_exam_class_released: false, fn_position_holders: HOLDERS,
  fn_class_streams: PUPILS.map((p, i) => ({ ...p, bise_reg_no: i === 0 ? '2026-BISE-01234' : i === 1 ? '2026-BISE-01234' : null, stream: i === 3 ? null : p.stream })),
  'table:school_settings': { name: 'Al Qalam Public School', pass_percent: 33 },
}

export const EXAM_SCENES: Record<string, Scene> = {
  'exams2-setup': { title: 'Exams: setup, Class 9', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=setup&term=term1&class=c9', seeds: [SEED_SESSION], data: base },
  'exams2-setup-empty': { title: 'Exams: no term yet', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=setup', seeds: [SEED_SESSION], data: { ...base, 'table:exam_terms': [] } },
  'exams2-streams': { title: 'Exams: streams', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=streams&term=term1&class=c9', seeds: [SEED_SESSION], data: base },
  'exams2-marks': { title: 'Exams: marks, papers', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=marks&term=term1&class=c9', seeds: [SEED_SESSION], data: base },
  'exams2-marks-grid': { title: 'Exams: marks, Physics', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=marks&term=term1&class=c9', seeds: [SEED_SESSION], data: { ...base, 'table:exam_subjects': [PAPERS[0]] } },
  'exams2-results': { title: 'Exams: the term at a glance', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=results&term=term1', seeds: [SEED_SESSION], data: base },
  'exams2-results-class': { title: 'Exams: Class 8 cards', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=results&term=term1&class=c8', seeds: [SEED_SESSION], data: base },
  'exams2-results-stale': { title: 'Exams: Class 10, out of date', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=results&term=term1&class=c10', seeds: [SEED_SESSION],
    data: { ...base, fn_result_readiness: [{ problem: 'cards out of date', detail: 'Marks have changed for 2 pupils since the cards were made. Generate them again to include the changes.', affected: 2 }] } },
  'exams2-remarks': { title: 'Exams: remarks', node: <ExamsPage />, profile: OWNER, route: '/exams?tab=remarks&term=term1&class=c8', seeds: [SEED_SESSION], data: base },
  'exams2-teacher-marks': { title: 'Exams: a subject teacher marks 9 A Physics', node: <ExamsPage />, profile: SUBJECT_TEACHER, route: '/exams', seeds: [SEED_SESSION],
    data: { ...base, fn_my_teaching: TEACHING } },
  'exams2-class-teacher': { title: 'Exams: a class teacher, remarks', node: <ExamsPage />, profile: CLASS_TEACHER, route: '/exams?tab=remarks&term=term1&class=c8', seeds: [SEED_SESSION],
    data: { ...base, fn_my_teaching: CT_TEACHING } },
}

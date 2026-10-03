/**
 * Previous dues (0153) in the live preview: Quick Add with a child's dues being
 * typed, the class grid with a Previous dues cell per row, and the Arrears list
 * with a child who owes only a named due.
 *
 * The typing is put into localStorage before the screen mounts (Scene.storage),
 * which is exactly where both screens keep a half-finished sitting, so what is
 * on screen is what a clerk who closed the laptop mid-row comes back to.
 */
import type { Scene } from './scenes'
import type { Profile } from '@/auth/AuthProvider'
import { QuickAdd } from '@/pages/students/QuickAdd'
import { BulkClassAdd } from '@/pages/students/BulkClassAdd'
import { Arrears } from '@/pages/fees/Arrears'
import { dueMonths } from '@/lib/dues'
import { DEMO_PROFILE, DEMO_SCHOOL } from '../demo-data'

const OWNER: Profile = { ...DEMO_PROFILE, role: 'owner' }
const SESSION = { id: 'ses-2627', name: DEMO_SCHOOL.session, is_current: true, is_closed: false, starts_on: '2026-04-01', ends_on: '2027-03-31' }

const FEE = [{
  fee_head_id: 'h1', fee_head: 'Monthly Fee', is_recurring: true, amount: 3500,
  effective_from: '2026-04-01', next_amount: null, next_from: null,
}]
const ROLL = { on_roll: 23, taken: Array.from({ length: 23 }, (_, i) => i + 1), unnumbered: 0, next_free: 24 }
const months = dueMonths()

const base = {
  fn_section_roll_state: ROLL,
  fn_fee_structure: FEE,
  fn_rde_add_students: { created: 0, failed: 0, drafts: 0, results: [] },
  fn_portal_targets: [],
}

const quickKept = {
  f: {
    full_name: 'Zainab Tariq', roll_no: '24', gr_no: '', father_name: 'Tariq Mehmood', mother_name: '',
    gender: 'female', b_form: '', father_cnic: '35202-1234567-1', dob: '2016-03-14', whatsapp: '0300 1234567',
  },
  rollTouched: false, paid: 'part', paidPart: '2,000',
  discOn: false, discType: 'sibling', discAmount: '', discPercent: true,
  duesOn: true,
  dues: JSON.stringify({
    months: { [months[0]]: '3500', [months[1]]: '3500', [months[2]]: '3000' },
    named: [
      { key: 'a', kind: 'admission', label: 'Admission fee', amount: '5,000' },
      { key: 'b', kind: 'stationery', label: 'Stationery', amount: '1200' },
      { key: 'c', kind: 'other', label: 'Picnic to Murree', amount: '800' },
    ],
  }),
  sibling: null,
}

const gridRows = [
  { roll_no: '24', full_name: 'Zainab Tariq', father_name: 'Tariq Mehmood', gender: 'female', dob: '14/03/2016',
    whatsapp: '03001234567', paid: 'y',
    dues: JSON.stringify({ months: { [months[0]]: '3500', [months[1]]: '3500' }, named: [{ key: 'a', kind: 'admission', label: 'Admission fee', amount: '5000' }] }) },
  { roll_no: '25', full_name: 'Hamza Iqbal', father_name: 'Iqbal Hussain', gender: 'male', dob: '02/11/2015', discount: '20' },
  { roll_no: '26', full_name: 'Ayesha Noor', father_name: 'Noor Ahmed', gender: 'female',
    dues: JSON.stringify({ months: {}, named: [{ key: 'b', kind: 'other', label: 'Lab charges', amount: '600' }] }) },
  { roll_no: '27', full_name: 'Usman Ali', father_name: 'Ali Raza', gender: 'male', dob: '30/07/2016', whatsapp: '03214567890' },
]

const quickNode = <QuickAdd sessionId={SESSION.id} sessionStart={SESSION.starts_on} classId="c4" sectionId="c4-a" />
const gridNode = <BulkClassAdd sessionId={SESSION.id} sessionStart={SESSION.starts_on} classId="c4" sectionId="c4-a" className="Class 4" sectionName="A" />

export const DUES_SCENES: Record<string, Scene> = {
  'dues-quick': {
    title: 'Quick Add, a child with previous dues', node: quickNode, profile: OWNER,
    route: '/students?add=quick', seeds: [[['currentSession'], SESSION]], data: base,
    storage: { 'rde.quick.c4.c4-a': JSON.stringify(quickKept) },
  },
  'dues-quick-empty': {
    title: 'Quick Add, empty', node: quickNode, profile: OWNER,
    route: '/students?add=quick', seeds: [[['currentSession'], SESSION]], data: base,
  },
  'dues-grid': {
    title: 'The class grid with previous dues per row', node: gridNode, profile: OWNER,
    route: '/students?add=bulk', seeds: [[['currentSession'], SESSION]], data: base,
    storage: { 'rde.grid.fees': '1', 'rde.grid.c4.c4-a': JSON.stringify(gridRows) },
  },
  'dues-arrears': {
    title: 'Arrears with named dues', node: <Arrears />, profile: OWNER, route: '/fees',
    seeds: [[['currentSession'], SESSION]],
    data: {
      fn_arrears: [
        { student_id: 's1', gr_no: '1204', full_name: 'Zainab Tariq', class_name: 'Class 4', section_name: 'A', roll_no: '24',
          family_id: 'f1', family_head: 'Tariq Mehmood', phone: '03001234567', months_owed: 3, oldest_month: months[2], amount: 16_200 },
        { student_id: 's2', gr_no: '1188', full_name: 'Ayesha Noor', class_name: 'Class 4', section_name: 'A', roll_no: '26',
          family_id: 'f2', family_head: 'Noor Ahmed', phone: '03111234567', months_owed: 0, oldest_month: null, amount: 600 },
        { student_id: 's3', gr_no: '1102', full_name: 'Bilal Hussain', class_name: 'Class 6', section_name: null, roll_no: '9',
          family_id: 'f3', family_head: 'Hussain Shah', phone: null, months_owed: 1, oldest_month: months[0], amount: 3_500 },
      ],
    },
  },
}

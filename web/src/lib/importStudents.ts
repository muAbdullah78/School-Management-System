/** Header canonicalisation for the bulk student importer.
 *
 *  Schools bring their own spreadsheet with whatever column headings they use
 *  ("Father Name", "DOB", "Class"). We normalise each heading and map it to the
 *  canonical key the `fn_import_students` RPC understands, so the operator never
 *  has to rename columns to match ours. Unknown columns are simply ignored.
 *
 *  Pure functions only (no I/O) so they are unit-tested and run in CI. */

export const STUDENT_IMPORT_COLUMNS = [
  'full_name', 'father_name', 'mother_name', 'gender', 'dob', 'b_form',
  'father_cnic',
  'phone', 'whatsapp', 'address',
  'class', 'section', 'roll_no', 'gr_no', 'admission_no', 'admission_date',
  'guardian_name', 'guardian_relation', 'guardian_phone', 'guardian_whatsapp',
] as const

export type StudentImportColumn = (typeof STUDENT_IMPORT_COLUMNS)[number]

/** Required to admit a row at all (everything else is optional). */
export const REQUIRED_IMPORT_COLUMNS: StudentImportColumn[] = ['full_name', 'class']

/** normalised-header → canonical-column. Keys are the output of normalizeHeader. */
const ALIASES: Record<string, StudentImportColumn> = {
  name: 'full_name', full_name: 'full_name', student_name: 'full_name',
  students_name: 'full_name', student: 'full_name',
  father: 'father_name', father_name: 'father_name', fathers_name: 'father_name',
  father_husband_name: 'father_name', guardian_father: 'father_name',
  mother: 'mother_name', mother_name: 'mother_name', mothers_name: 'mother_name',
  gender: 'gender', sex: 'gender',
  dob: 'dob', date_of_birth: 'dob', birth_date: 'dob', birthday: 'dob',
  b_form: 'b_form', bform: 'b_form', b_form_no: 'b_form', bform_no: 'b_form',
  b_form_number: 'b_form', bay_form: 'b_form', child_cnic: 'b_form',
  student_cnic: 'b_form',

  // A column headed just "CNIC" in a Pakistani school register is the PARENT's,
  // not the child's — children carry a B-Form, adults carry a CNIC, and B-Form
  // columns are labelled as such (handled above). This used to map to b_form,
  // which was wrong twice over: it filed an adult's ID as the child's, and it
  // discarded the one value that puts siblings in a single family for billing.
  //
  // If a register really does mean the student's own CNIC (an over-18 in
  // matric), the cost of this choice is nil: their CNIC is unique to them, so
  // they land in a family of their own exactly as they would have anyway.
  cnic: 'father_cnic', cnic_no: 'father_cnic', cnic_number: 'father_cnic',
  father_cnic: 'father_cnic', fathers_cnic: 'father_cnic',
  father_cnic_no: 'father_cnic', guardian_cnic: 'father_cnic',
  parent_cnic: 'father_cnic', father_nic: 'father_cnic', nic: 'father_cnic',
  phone: 'phone', mobile: 'phone', contact: 'phone', phone_no: 'phone',
  mobile_no: 'phone', contact_no: 'phone', cell: 'phone',
  whatsapp: 'whatsapp', whatsapp_no: 'whatsapp', whatsapp_number: 'whatsapp', wa: 'whatsapp',
  address: 'address', home_address: 'address', residence: 'address',
  class: 'class', class_name: 'class', grade: 'class', class_grade: 'class',
  section: 'section', section_name: 'section',
  roll: 'roll_no', roll_no: 'roll_no', roll_number: 'roll_no', rollno: 'roll_no',
  gr: 'gr_no', gr_no: 'gr_no', gr_number: 'gr_no', grno: 'gr_no',
  gr_no_general_register: 'gr_no', general_register_no: 'gr_no',
  admission_no: 'admission_no', admission_number: 'admission_no', adm_no: 'admission_no',
  reg_no: 'admission_no', registration_no: 'admission_no', enrollment_no: 'admission_no',
  admission_date: 'admission_date', doa: 'admission_date', date_of_admission: 'admission_date',
  admitted_on: 'admission_date',
  guardian_name: 'guardian_name', guardian: 'guardian_name', parent_name: 'guardian_name',
  guardian_relation: 'guardian_relation', relation: 'guardian_relation', relationship: 'guardian_relation',
  guardian_phone: 'guardian_phone', guardian_contact: 'guardian_phone', guardian_mobile: 'guardian_phone',
  guardian_whatsapp: 'guardian_whatsapp',
}

/** Lower-case, drop apostrophes, collapse any run of non-alphanumerics to a single
 *  underscore, and trim underscores. "Father's Name" → "father_s_name"?  No — the
 *  apostrophe is dropped first, so → "fathers_name". */
export function normalizeHeader(header: string): string {
  return header
    .trim()
    .toLowerCase()
    .replace(/['’`]/g, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
}

/** Map one raw heading to a canonical column, or null if we don't recognise it. */
export function canonicalColumn(header: string): StudentImportColumn | null {
  return ALIASES[normalizeHeader(header)] ?? null
}

/** Map a raw parsed row (arbitrary headings) to canonical keys. Blank values and
 *  unrecognised columns are dropped so the RPC receives a clean, minimal object. */
export function mapImportRow(raw: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    const col = canonicalColumn(key)
    if (!col) continue
    const v = value == null ? '' : String(value).trim()
    if (v !== '') out[col] = v
  }
  return out
}

export function mapImportRows(raws: Record<string, string>[]): Record<string, string>[] {
  return raws.map(mapImportRow)
}

/** Required canonical columns that the given headings don't cover — for a friendly
 *  pre-flight warning before the operator even uploads. */
export function missingRequiredColumns(headers: string[]): StudentImportColumn[] {
  const present = new Set(
    headers.map(canonicalColumn).filter((c): c is StudentImportColumn => c !== null),
  )
  return REQUIRED_IMPORT_COLUMNS.filter((c) => !present.has(c))
}

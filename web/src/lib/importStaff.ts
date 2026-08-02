/** Header canonicalisation for the staff importer — sibling of importStudents.ts
 *  / importBalances.ts. Maps the school's own headings to the keys the
 *  fn_import_staff RPC understands. */

import { normalizeHeader } from './importStudents'

export const STAFF_IMPORT_COLUMNS = [
  'full_name', 'designation', 'employee_no', 'mobile', 'whatsapp', 'cnic', 'joined_on',
] as const

export type StaffImportColumn = (typeof STAFF_IMPORT_COLUMNS)[number]

const ALIASES: Record<string, StaffImportColumn> = {
  name: 'full_name', full_name: 'full_name', staff_name: 'full_name', employee_name: 'full_name', teacher_name: 'full_name',
  designation: 'designation', role: 'designation', post: 'designation', title: 'designation', position: 'designation',
  employee_no: 'employee_no', employee_id: 'employee_no', emp_no: 'employee_no', emp_id: 'employee_no', staff_id: 'employee_no',
  mobile: 'mobile', phone: 'mobile', mobile_no: 'mobile', contact: 'mobile', contact_no: 'mobile', cell: 'mobile',
  whatsapp: 'whatsapp', whatsapp_no: 'whatsapp', wa: 'whatsapp',
  cnic: 'cnic', cnic_no: 'cnic', nic: 'cnic', id_card: 'cnic', national_id: 'cnic',
  joined_on: 'joined_on', joining_date: 'joined_on', date_of_joining: 'joined_on', doj: 'joined_on', joined: 'joined_on', hired_on: 'joined_on',
}

export function canonicalStaffColumn(header: string): StaffImportColumn | null {
  return ALIASES[normalizeHeader(header)] ?? null
}

export function mapStaffRow(raw: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    const col = canonicalStaffColumn(key)
    if (!col) continue
    const v = value == null ? '' : String(value).trim()
    if (v !== '') out[col] = v
  }
  return out
}

export function mapStaffRows(raws: Record<string, string>[]): Record<string, string>[] {
  return raws.map(mapStaffRow)
}

export function missingStaffColumns(headers: string[]): string[] {
  const present = new Set(headers.map(canonicalStaffColumn).filter((c): c is StaffImportColumn => c !== null))
  return present.has('full_name') ? [] : ['full_name']
}

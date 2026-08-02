/** Header canonicalisation for the opening fee-balance importer — sibling of
 *  importStudents.ts. Maps the school's own headings ("Balance", "Arrears",
 *  "Outstanding", "Dues") to the canonical keys fn_import_opening_balances reads.
 *
 *  A row identifies a student (GR No / Admission No / Name) and carries the
 *  amount they owe. Pure functions only, so they're unit-tested and run in CI. */

import { normalizeHeader } from './importStudents'

export const BALANCE_IMPORT_COLUMNS = [
  'gr_no', 'admission_no', 'full_name', 'father_name', 'amount', 'due_date',
] as const

export type BalanceImportColumn = (typeof BALANCE_IMPORT_COLUMNS)[number]

const ALIASES: Record<string, BalanceImportColumn> = {
  gr: 'gr_no', gr_no: 'gr_no', gr_number: 'gr_no', grno: 'gr_no',
  gr_no_general_register: 'gr_no', general_register_no: 'gr_no',
  admission_no: 'admission_no', admission_number: 'admission_no', adm_no: 'admission_no',
  reg_no: 'admission_no', registration_no: 'admission_no',
  name: 'full_name', full_name: 'full_name', student_name: 'full_name', student: 'full_name',
  father: 'father_name', father_name: 'father_name', fathers_name: 'father_name',
  amount: 'amount', opening_balance: 'amount', opening: 'amount', opening_arrears: 'amount',
  arrears: 'amount', arrear: 'amount', balance: 'amount', outstanding: 'amount',
  outstanding_balance: 'amount', outstanding_amount: 'amount', dues: 'amount', due_amount: 'amount',
  previous_balance: 'amount', prev_balance: 'amount', old_balance: 'amount',
  brought_forward: 'amount', b_f: 'amount', bf: 'amount', carry_forward: 'amount',
  due_date: 'due_date', duedate: 'due_date', last_date: 'due_date', pay_by: 'due_date',
  payable_by: 'due_date',
}

export function canonicalBalanceColumn(header: string): BalanceImportColumn | null {
  return ALIASES[normalizeHeader(header)] ?? null
}

export function mapBalanceRow(raw: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const [key, value] of Object.entries(raw)) {
    const col = canonicalBalanceColumn(key)
    if (!col) continue
    const v = value == null ? '' : String(value).trim()
    if (v !== '') out[col] = v
  }
  return out
}

export function mapBalanceRows(raws: Record<string, string>[]): Record<string, string>[] {
  return raws.map(mapBalanceRow)
}

/** `amount` is always required; a student identifier (GR / Admission No / Name)
 *  must also be present. Returns the human-readable list of what's missing. */
export function missingBalanceColumns(headers: string[]): string[] {
  const present = new Set(
    headers.map(canonicalBalanceColumn).filter((c): c is BalanceImportColumn => c !== null),
  )
  const missing: string[] = []
  if (!present.has('amount')) missing.push('amount')
  if (!present.has('gr_no') && !present.has('admission_no') && !present.has('full_name')) {
    missing.push('a student identifier (gr_no, admission_no or full_name)')
  }
  return missing
}

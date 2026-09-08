import { describe, expect, it } from 'vitest'
import { describeAudit, areaLabel } from '@/pages/settings/AuditLog'

/**
 * The audit log screen showed the database's own words.
 *
 * `INSERT` / `attendance_daily` is the correct thing to store and the wrong
 * thing to print: the owner reading it is looking for "who reopened last
 * Tuesday's register", and no part of that sentence appears in either column.
 * Migration 0126 made it urgent by adding ATTENDANCE_FINALIZE and
 * ASSESSMENT_LOCK, which would have arrived on screen shouting.
 *
 * These are the seventeen tables that carry the audit trigger and the five
 * named actions the functions write, listed here so a table or an action added
 * later fails this file instead of reaching a school as jargon.
 */
const AUDITED_TABLES = [
  'adjustments', 'admission_enquiries', 'attendance_daily', 'certificates',
  'discounts', 'enquiry_contacts', 'exam_remarks', 'expense_categories',
  'expenses', 'families', 'mark_entries', 'other_income', 'payments',
  'staff_attendance', 'student_links', 'teacher_assignments', 'till_sessions',
]

/** Written by a function rather than by the trigger, so entity varies. */
const NAMED_ACTIONS: [string, string][] = [
  ['ATTENDANCE_FINALIZE', 'attendance_daily'],
  ['ATTENDANCE_UNLOCK', 'attendance_daily'],
  ['ASSESSMENT_LOCK', 'assessments'],
  ['STUDENT_STATUS', 'students'],
  ['INVOICE_VOID', 'invoices'],
]

describe('the audit log says what happened', () => {
  it('never prints a table name as the area', () => {
    for (const t of AUDITED_TABLES) {
      expect(areaLabel(t), t).not.toBe(t)
      expect(areaLabel(t), t).not.toMatch(/_/)
    }
    for (const [, entity] of NAMED_ACTIONS) {
      expect(areaLabel(entity), entity).not.toMatch(/_/)
    }
  })

  it('never prints a SQL verb or a shouted action as what happened', () => {
    const pairs: [string, string][] = [
      ...NAMED_ACTIONS,
      ...AUDITED_TABLES.flatMap((t) =>
        (['INSERT', 'UPDATE', 'DELETE'] as const).map((a) => [a, t] as [string, string])),
    ]
    for (const [action, entity] of pairs) {
      const said = describeAudit(action, entity)
      expect(said, `${action} ${entity}`).not.toMatch(/INSERT|UPDATE|DELETE/)
      // No SHOUTING_SNAKE_CASE, and no table name left in the sentence.
      expect(said, `${action} ${entity}`).not.toMatch(/[A-Z]{2,}/)
      expect(said, `${action} ${entity}`).not.toMatch(/_/)
      expect(said.length, `${action} ${entity}`).toBeGreaterThan(3)
    }
  })

  it('names the two rows migration 0126 introduced, in words a school uses', () => {
    expect(describeAudit('ATTENDANCE_FINALIZE', 'attendance_daily'))
      .toBe('Register finalised and locked')
    expect(describeAudit('ASSESSMENT_LOCK', 'assessments')).toBe('Test locked')
    // And the pair it belongs with, from 0121.
    expect(describeAudit('ATTENDANCE_UNLOCK', 'attendance_daily'))
      .toBe('Register reopened')
  })

  it('reads correctly for the corrections that are now the only register rows', () => {
    // After 0126 an attendance row in the log is always a correction, never a
    // first entry, so "Register added" must not be reachable.
    expect(describeAudit('UPDATE', 'attendance_daily')).toBe('Attendance corrected')
    expect(describeAudit('UPDATE', 'mark_entries')).toBe('Mark corrected')
  })

  it('degrades into English rather than into nothing', () => {
    // A table or an action this file has not heard of still has to render, and
    // has to render as a sentence. A log that hides a row it cannot label is
    // a log that lies.
    expect(describeAudit('INSERT', 'some_new_table')).toBe('some_new_table added')
    // No area prefix on an unknown action: the Area column carries it, and
    // "Fee payments something new" is worse English than "Something new".
    expect(describeAudit('SOMETHING_NEW', 'payments')).toBe('Something new')
    expect(areaLabel('some_new_table')).toBe('some_new_table')
  })
})

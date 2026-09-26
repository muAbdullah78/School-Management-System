/**
 * What a teacher may pick, from what they teach.
 *
 * The same rule as the database's fn_may_set_a_test (0135, 0151), worked out
 * on the screen so a picker never offers a choice the database will refuse:
 *
 *   * the class teacher of a class (or of one of its sections) may set a test
 *     in ANY subject there, or in no subject at all,
 *   * a subject teacher may set one only in their own subject,
 *   * a test for the whole class (no section) needs whole-class cover: a class
 *     teacher of the whole class, or a subject assignment with no section.
 *     A section's teacher picks their section, never "All".
 */
import type { MyTeachingRow } from './db'

export interface TaughtClass { class_id: string; class_name: string; level_order: number }

/** Every class the teacher teaches anything in, in school order, once each. */
export function taughtClasses(rows: MyTeachingRow[]): TaughtClass[] {
  const seen = new Map<string, TaughtClass>()
  for (const r of rows) {
    if (!seen.has(r.class_id)) seen.set(r.class_id, { class_id: r.class_id, class_name: r.class_name, level_order: r.level_order })
  }
  return [...seen.values()].sort((a, b) => a.level_order - b.level_order || a.class_name.localeCompare(b.class_name))
}

/** The rows that cover one section of a class. A row with no section covers
 *  every section; a null `sectionId` (a whole-class test) is covered only by
 *  rows with no section. */
function covering(rows: MyTeachingRow[], classId: string, sectionId: string | null): MyTeachingRow[] {
  return rows.filter((r) => r.class_id === classId
    && (r.section_id === null || (sectionId !== null && r.section_id === sectionId)))
}

/**
 * The sections of a class the teacher may act in.
 * `whole` is true when they may also act for the whole class at once;
 * `ids` is null when every section is theirs.
 */
export function sectionScope(rows: MyTeachingRow[], classId: string): { whole: boolean; ids: Set<string> | null } {
  const mine = rows.filter((r) => r.class_id === classId)
  const whole = mine.some((r) => r.section_id === null)
  return { whole, ids: whole ? null : new Set(mine.map((r) => r.section_id).filter(Boolean) as string[]) }
}

/**
 * The subjects the teacher may set a test in, for one section of a class.
 * `any` means every subject of the class and "no subject" too (a class
 * teacher); otherwise only the listed subject ids.
 */
export function subjectScope(rows: MyTeachingRow[], classId: string, sectionId: string | null): { any: boolean; ids: Set<string> } {
  const cover = covering(rows, classId, sectionId)
  return {
    any: cover.some((r) => r.is_class_teacher),
    ids: new Set(cover.filter((r) => !r.is_class_teacher && r.subject_id).map((r) => r.subject_id as string)),
  }
}

/** True when the teacher is the class teacher of at least one class. The daily
 *  register is theirs alone (0134). */
export function isClassTeacherAnywhere(rows: MyTeachingRow[]): boolean {
  return rows.some((r) => r.is_class_teacher)
}

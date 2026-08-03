/** Pure helpers for the year-end rollover UI. The server (fn_rollover) is the
 *  source of truth; these just pre-fill sensible defaults the operator can tweak. */

export type RolloverAction = 'promote' | 'retain' | 'graduate'

export interface RolloverRule {
  action: RolloverAction
  toClassId: string | null
}

export interface ClassLite {
  id: string
  name: string
  level_order: number
}

/** The class one level up from `cls`, or null if `cls` is the top of the ladder. */
export function nextClass(cls: ClassLite, classes: ClassLite[]): ClassLite | null {
  return (
    classes
      .filter((c) => c.level_order > cls.level_order)
      .sort((a, b) => a.level_order - b.level_order)[0] ?? null
  )
}

/** Default rule per class: promote to the next class up, or graduate if it's the
 *  top class. The operator can override any of these before committing. */
export function defaultRolloverRules(classes: ClassLite[]): Record<string, RolloverRule> {
  const out: Record<string, RolloverRule> = {}
  for (const c of classes) {
    const nxt = nextClass(c, classes)
    out[c.id] = nxt ? { action: 'promote', toClassId: nxt.id } : { action: 'graduate', toClassId: null }
  }
  return out
}

/** Shape the rules map into the array fn_rollover expects. */
export function rulesToPayload(
  rules: Record<string, RolloverRule>,
): { from_class_id: string; action: RolloverAction; to_class_id: string | null }[] {
  return Object.entries(rules).map(([from_class_id, r]) => ({
    from_class_id,
    action: r.action,
    to_class_id: r.action === 'promote' ? r.toClassId : null,
  }))
}

import { describe, it, expect } from 'vitest'
import { nextClass, defaultRolloverRules, rulesToPayload, type ClassLite } from './rollover'

const CLASSES: ClassLite[] = [
  { id: 'c1', name: 'Class 1', level_order: 1 },
  { id: 'c2', name: 'Class 2', level_order: 2 },
  { id: 'c10', name: 'Class 10', level_order: 10 },
]

describe('nextClass', () => {
  it('returns the next class up by level_order', () => {
    expect(nextClass(CLASSES[0], CLASSES)?.id).toBe('c2')
    expect(nextClass(CLASSES[1], CLASSES)?.id).toBe('c10')
  })
  it('returns null for the top class', () => {
    expect(nextClass(CLASSES[2], CLASSES)).toBeNull()
  })
})

describe('defaultRolloverRules', () => {
  it('promotes each class to the next and graduates the top class', () => {
    expect(defaultRolloverRules(CLASSES)).toEqual({
      c1: { action: 'promote', toClassId: 'c2' },
      c2: { action: 'promote', toClassId: 'c10' },
      c10: { action: 'graduate', toClassId: null },
    })
  })
})

describe('rulesToPayload', () => {
  it('drops to_class_id for non-promote actions', () => {
    const payload = rulesToPayload({
      c1: { action: 'promote', toClassId: 'c2' },
      c2: { action: 'retain', toClassId: 'c2' },
      c10: { action: 'graduate', toClassId: null },
    })
    expect(payload).toEqual([
      { from_class_id: 'c1', action: 'promote', to_class_id: 'c2' },
      { from_class_id: 'c2', action: 'retain', to_class_id: null },
      { from_class_id: 'c10', action: 'graduate', to_class_id: null },
    ])
  })
})

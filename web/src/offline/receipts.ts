// Receipt numbers a device may print without asking the server.
//
// fn_sync_hello gives a device that takes fees one or two blocks of numbers off
// the school's own counter. The device prints them in order, lowest block
// first, and reports the next one it would use at every hello, which is how the
// server knows a block is finished and when to give another. A number is taken
// in the same IndexedDB transaction that saves the payment (see store.ts), so
// two tabs can never print the same one.
import type { ReceiptBlock } from './server'

function sorted(blocks: ReceiptBlock[]): ReceiptBlock[] {
  return [...blocks].sort((a, b) => a.first_no - b.first_no)
}

/**
 * The number to print now and the next one after it. `next` is where the
 * device got to (null before its first number). Null when every block is used
 * up: the payment is then saved without a number and the server gives it one
 * when it arrives.
 */
export function takeReceipt(blocks: ReceiptBlock[], next: number | null): { number: number | null; next: number | null } {
  for (const b of sorted(blocks)) {
    const from = next == null ? b.first_no : Math.max(next, b.first_no)
    if (from <= b.last_no) return { number: from, next: from + 1 }
  }
  return { number: null, next }
}

/** Where the device stands after a hello: on its next unused number, or null if it has none left. */
export function settleNext(blocks: ReceiptBlock[], next: number | null): number | null {
  return takeReceipt(blocks, next).number ?? next
}

/** How many numbers are left to print. */
export function receiptsLeft(blocks: ReceiptBlock[], next: number | null): number {
  let n = 0
  for (const b of sorted(blocks)) {
    const from = next == null ? b.first_no : Math.max(next, b.first_no)
    if (from <= b.last_no) n += b.last_no - from + 1
  }
  return n
}

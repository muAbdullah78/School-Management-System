// The device keeps its clock to the server's.
//
// A phone's clock can be wrong by minutes or by years, and it can be changed by
// hand. Every command carries when it was made on the SERVER's clock: the
// device's own time plus the offset measured at the last hello. A clock moved
// backwards while offline would stretch the seven-day lease, so a backwards
// jump is noticed and offline work stops until the next hello measures again.
// A clock moved forwards only shortens the lease, and the server refuses a time
// more than ten minutes ahead of its own.

/** How far a clock may step back (an NTP correction, a phone settling) before it counts. */
export const BACKWARDS_TOLERANCE_MS = 2 * 60 * 1000

export interface ClockState {
  /** Server time minus device time, in milliseconds, as last measured. */
  offset_ms: number
  /** Device time of that measurement; null until the first hello. */
  measured_wall: number | null
  /** The latest device time this app has seen. A later reading below it means the clock went back. */
  last_seen_wall: number
}

export const NO_CLOCK: ClockState = { offset_ms: 0, measured_wall: null, last_seen_wall: 0 }

/**
 * The offset from one round trip: the server read its clock somewhere between
 * the request leaving and the answer arriving, and the middle is the best guess.
 * On a slow connection that guess is off by up to half the round trip, which
 * is why the server allows ten minutes.
 */
export function measure(serverTimeIso: string, sentWall: number, receivedWall: number): ClockState {
  const server = Date.parse(serverTimeIso)
  const mid = sentWall + (receivedWall - sentWall) / 2
  return { offset_ms: Math.round(server - mid), measured_wall: receivedWall, last_seen_wall: receivedWall }
}

/** True when the device clock has been moved back since this app last looked at it. */
export function wentBackwards(state: ClockState, nowWall: number): boolean {
  return state.last_seen_wall - nowWall > BACKWARDS_TOLERANCE_MS
}

/** The clock after looking at it now: the latest time seen only ever moves forwards. */
export function observe(state: ClockState, nowWall: number): ClockState {
  return nowWall > state.last_seen_wall ? { ...state, last_seen_wall: nowWall } : state
}

/** The server's time now, by this device's reckoning. */
export function serverNow(state: ClockState, nowWall: number): number {
  return nowWall + state.offset_ms
}

/**
 * "You can look at this and not change it."
 *
 * Shown on every screen an observer (`readonly`) can reach that would normally
 * offer write controls. It exists because the alternative — a screen that simply
 * has no buttons — reads as a broken or half-loaded page, and the user's next
 * move is to report a fault.
 *
 * The database refuses these writes regardless, and since 0059 a refused write
 * fails LOUDLY rather than reporting success (RLS makes a blocked UPDATE affect
 * zero rows without raising, which used to mean "Saved." over an unchanged
 * record). This banner is so nobody has to discover that by pressing a button.
 *
 * See docs/READONLY-DESIGN.md.
 */
export function ObserverNotice({ what }: {
  /** What is being observed, in the plural: "fee records", "staff records". */
  what?: string
}) {
  return (
    <div className="mb-4 flex items-start gap-2 rounded-lg border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600 print:hidden">
      <span aria-hidden className="mt-0.5 text-slate-400">👁</span>
      <span>
        You are signed in as an <strong>observer</strong>. You can see
        {what ? ` all ${what}` : ' everything on this screen'} and change nothing.
        Ask the school owner for a different role if you need to make changes.
      </span>
    </div>
  )
}

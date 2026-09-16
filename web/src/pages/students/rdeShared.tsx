/**
 * The pieces Quick Add and the bulk grid both need.
 *
 * THE DATE BOX IS THREE BOXES, and that is the considered answer rather than a
 * shortcut. <input type="date"> renders a calendar a clerk must navigate back
 * eight years to reach a 2018 birthday, and its text form follows the browser's
 * locale, so "04/11/2018" means April on one machine and November on another
 * while the register in front of them says neither. Three numeric boxes labelled
 * DD MM YYYY that advance by themselves take six keystrokes, cannot be read two
 * ways, and work the same on a phone.
 */
import { useRef, useState, useEffect } from 'react'

export const FIELD =
  'w-full rounded border border-slate-300 px-2.5 py-1.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

/** "2026-09-16" from three parts, or null while any of them is still short. */
export function partsToISO(d: string, m: string, y: string): string | null {
  if (d.length === 0 && m.length === 0 && y.length === 0) return null
  if (y.length !== 4 || m.length === 0 || d.length === 0) return null
  const dd = Number(d), mm = Number(m), yy = Number(y)
  if (!dd || !mm || !yy || mm > 12 || dd > 31) return null
  // Round-tripped through Date so 31 February comes back as null rather than
  // silently becoming 3 March, which is what a bare string would do.
  const iso = `${yy}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`
  const t = new Date(`${iso}T00:00:00Z`)
  if (Number.isNaN(t.getTime()) || t.getUTCDate() !== dd || t.getUTCMonth() + 1 !== mm) return null
  return iso
}

export function DateTriple({
  value, onChange, ariaLabel = 'Date of birth',
}: { value: string | null; onChange: (iso: string | null) => void; ariaLabel?: string }) {
  const [d, setD] = useState(value ? value.slice(8, 10) : '')
  const [m, setM] = useState(value ? value.slice(5, 7) : '')
  const [y, setY] = useState(value ? value.slice(0, 4) : '')
  const mRef = useRef<HTMLInputElement>(null)
  const yRef = useRef<HTMLInputElement>(null)

  // Kept in step when the parent clears the form after a save.
  useEffect(() => {
    if (value) { setD(value.slice(8, 10)); setM(value.slice(5, 7)); setY(value.slice(0, 4)) }
    else if (d || m || y) { setD(''); setM(''); setY('') }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value])

  function push(nd: string, nm: string, ny: string) {
    onChange(partsToISO(nd, nm, ny))
  }
  const box = 'rounded border border-slate-300 px-2 py-1.5 text-center text-sm tabular-nums focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500'

  return (
    <span className="flex items-center gap-1" role="group" aria-label={ariaLabel}>
      <input
        inputMode="numeric" maxLength={2} placeholder="DD" aria-label="Day" value={d}
        onChange={(e) => {
          const v = e.target.value.replace(/\D/g, '').slice(0, 2)
          setD(v); push(v, m, y)
          if (v.length === 2) mRef.current?.focus()
        }}
        className={`${box} w-11`}
      />
      <span className="text-slate-300">/</span>
      <input
        ref={mRef} inputMode="numeric" maxLength={2} placeholder="MM" aria-label="Month" value={m}
        onChange={(e) => {
          const v = e.target.value.replace(/\D/g, '').slice(0, 2)
          setM(v); push(d, v, y)
          if (v.length === 2) yRef.current?.focus()
        }}
        className={`${box} w-11`}
      />
      <span className="text-slate-300">/</span>
      <input
        ref={yRef} inputMode="numeric" maxLength={4} placeholder="YYYY" aria-label="Year" value={y}
        onChange={(e) => {
          const v = e.target.value.replace(/\D/g, '').slice(0, 4)
          setY(v); push(d, m, v)
        }}
        className={`${box} w-16`}
      />
    </span>
  )
}

/**
 * What this record is still short of, named.
 *
 * The SAME four fields the database decides on in trg_students_draft. Two lists
 * that can disagree is how a screen ends up promising "complete" while the
 * dashboard keeps asking, so if this one is ever changed, that trigger is the
 * other half of the change.
 */
export function missingFields(r: {
  father_name?: string | null; gender?: string | null; dob?: string | null
  phone?: string | null; whatsapp?: string | null
}): string[] {
  const out: string[] = []
  if (!r.father_name?.trim()) out.push("father's name")
  if (!r.gender) out.push('gender')
  if (!r.dob) out.push('date of birth')
  if (!r.phone?.trim() && !r.whatsapp?.trim()) out.push('a phone number')
  return out
}

/** The finished months of this school year, newest first: what arrears can be for. */
export function finishedMonths(sessionStart: string | null): string[] {
  if (!sessionStart) return []
  const out: string[] = []
  // Karachi, not the browser: for five hours every morning a UTC machine is
  // still on yesterday, and at a month boundary that offers a month that has
  // not finished.
  const k = new Date(Date.now() + 5 * 60 * 60 * 1000)
  let y = k.getUTCFullYear()
  let m = k.getUTCMonth() + 1
  const [sy, sm] = sessionStart.split('-').map(Number)
  for (let i = 0; i < 24; i++) {
    m -= 1
    if (m === 0) { m = 12; y -= 1 }
    if (y < sy || (y === sy && m < sm)) break
    out.push(`${y}-${String(m).padStart(2, '0')}-01`)
  }
  return out
}

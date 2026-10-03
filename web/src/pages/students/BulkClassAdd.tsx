/**
 * The paper register, typed straight down.
 *
 * WHY THIS IS NOT A CONTROLLED REACT FORM, and it is the whole engineering of
 * the screen. A hundred rows of nine fields is nine hundred inputs. If each one
 * is `value={state[i][k]}` then every keystroke sets state, React reconciles
 * nine hundred inputs, and the clerk watches their own typing arrive late. At
 * that point they stop trusting the software and go back to the register.
 *
 * So the cells are UNCONTROLLED. Each renders once with a defaultValue, and a
 * keystroke writes into a ref, which React does not watch. React state holds one
 * thing only: the LIST OF ROW IDS. That changes when a row is added or removed
 * and at no other time, so typing costs one DOM write and no reconciliation at
 * all, whether there are ten rows or two hundred.
 *
 * WHAT A REF COSTS, stated plainly: the DOM is the source of truth between
 * saves, so anything that re-mounts the grid loses what is not in the ref. The
 * ref is written on every keystroke and mirrored to localStorage on a 600ms
 * debounce, keyed by class and section, so a refresh, a crashed tab or a closed
 * laptop gives the typing back. Forty rows of work is not something a browser
 * should be able to destroy.
 *
 * TAB AT THE END MAKES A ROW. Not a button: a clerk reading names aloud off a
 * register never takes their hands off the keyboard, and reaching for "add row"
 * once per child is the difference between this and the admission form.
 *
 * PREVIOUS DUES ARE PER CHILD. The grid used to take one "Owes Rs" figure per
 * row against ONE month chosen above the grid for everybody, read at the moment
 * of saving: a child owing three months was recorded as owing one, a change of
 * the month part way through re-dated every row already typed, and an
 * admission fee or a stationery bill had nowhere to go. Each row now has its
 * own Dues cell, which opens the same editor Quick Add uses.
 */
import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  rdeAddStudents, getSectionRollState, freeRolls, getFeeStructure, newRequestId,
  listPortalTargets, createFamilyPortals,
  type RdeRow, type RdeResultRow,
} from '@/lib/db'
import { fmtAmount, fmtMonth, grLabel } from '@/lib/format'
import {
  checkDues, decodeDues, dueMonths, duesSummary, encodeDues, isDuesEmpty, parseAmount,
} from '@/lib/dues'
import { DuesDialog } from './DuesEditor'
import { Card, CardTitle, Button, Badge } from '@/components/ui'
import { IconStudents, IconCheck, IconAlert } from '@/components/icons'
import { AskDialog } from '@/components/AskDialog'

type Field =
  | 'roll_no' | 'full_name' | 'father_name' | 'mother_name'
  | 'gender' | 'dob' | 'whatsapp' | 'father_cnic' | 'gr_no'
  | 'paid' | 'discount' | 'dues'

type Col = {
  key: Field; label: string; width: string
  kind?: 'select' | 'num' | 'check' | 'dues'
  /** Hidden until the clerk asks for the fee columns. */
  fee?: boolean
  title?: string
}

/* THE FEE COLUMNS ARE OFF BY DEFAULT, and that is the answer to "put the money
   on the grid without bloating it". A school typing four hundred names wants
   nine columns; a school entering the fees as it goes wants twelve. Three narrow
   ones behind a switch serve both. */
const COLS: Col[] = [
  { key: 'roll_no',     label: 'Roll',            width: 'w-16',  kind: 'num' },
  { key: 'full_name',   label: 'Name',            width: 'w-52' },
  { key: 'father_name', label: 'Father',          width: 'w-44' },
  { key: 'mother_name', label: 'Mother',          width: 'w-40' },
  { key: 'gender',      label: 'M/F',             width: 'w-20',  kind: 'select' },
  { key: 'dob',         label: 'DOB dd/mm/yyyy',  width: 'w-32' },
  { key: 'whatsapp',    label: 'WhatsApp',        width: 'w-36',  kind: 'num' },
  { key: 'father_cnic', label: 'Father CNIC',     width: 'w-40',  kind: 'num' },
  { key: 'gr_no',       label: 'GR',              width: 'w-24' },
  { key: 'paid',        label: 'Paid',            width: 'w-12',  kind: 'check', fee: true,
    title: "This month's fee is already collected" },
  { key: 'discount',    label: 'Disc %',          width: 'w-16',  kind: 'num', fee: true,
    title: 'A concession, as a percentage of the monthly fee' },
  { key: 'dues',        label: 'Previous dues',   width: 'w-36',  kind: 'dues', fee: true,
    title: 'Months of fee and anything else the child already owed. Enter opens it.' },
]

/** A cell's value. 'arrears' is the old "Owes Rs" cell, read from a draft kept before 0153. */
type RowData = Partial<Record<Field | 'arrears', string>>

/** "11/4/2018", "11-4-2018" or "2018-04-11" to an ISO date, else null. */
export function parseLooseDate(raw: string | undefined): string | null {
  const t = (raw ?? '').trim()
  if (!t) return null
  let dd: number, mm: number, yy: number
  const iso = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(t)
  if (iso) { yy = +iso[1]; mm = +iso[2]; dd = +iso[3] }
  else {
    // DD/MM/YYYY, which is what a Pakistani register is written in. Never
    // MM/DD: guessing by value ("13 must be the day") gets the first twelve
    // days of every month wrong and nobody notices for a year.
    const m = /^(\d{1,2})[/\-. ](\d{1,2})[/\-. ](\d{2}|\d{4})$/.exec(t)
    if (!m) return null
    dd = +m[1]; mm = +m[2]; yy = +m[3]
    if (yy < 100) yy += yy > 40 ? 1900 : 2000
  }
  if (!dd || !mm || !yy || mm > 12 || dd > 31) return null
  const d = new Date(Date.UTC(yy, mm - 1, dd))
  if (d.getUTCDate() !== dd || d.getUTCMonth() + 1 !== mm) return null
  return `${yy}-${String(mm).padStart(2, '0')}-${String(dd).padStart(2, '0')}`
}

/**
 * Blank row: nothing typed anywhere.
 *
 * THE ROLL DOES NOT COUNT. The grid fills every empty Roll cell with a free
 * number before anybody types, so counting it made every untouched row "typed
 * in": twelve roll-only rows were kept on disk, came back as "12 rows came back
 * from your last sitting" on a class nobody had touched, grew by one on every
 * visit, and carried roll numbers that might have been taken since.
 */
export function isBlank(r: RowData): boolean {
  return !Object.entries(r).some(([k, v]) => k !== 'roll_no' && (v ?? '').trim().length > 0)
}

/** Any money typed on this row, shown or not. */
function hasFees(r: RowData): boolean {
  return (r.paid ?? '') === 'y' || !!(r.discount ?? '').trim() || !!(r.dues ?? '').trim() || !!(r.arrears ?? '').trim()
}

/** The largest list fn_rde_add_students takes in one call. */
const CHUNK = 200

let seq = 0
const newId = () => `r${++seq}`

export function BulkClassAdd({
  sessionId, sessionStart, classId, sectionId, className, sectionName,
}: {
  sessionId: string; sessionStart: string | null
  classId: string; sectionId: string
  className: string; sectionName: string
}) {
  const qc = useQueryClient()
  const cacheKey = `rde.grid.${classId}.${sectionId || 'none'}`

  // THE STORE. React never reads this during render, so writing to it costs
  // nothing. Keyed by row id rather than by index, because removing a saved row
  // would otherwise shift every row's data up by one.
  const store = useRef<Map<string, RowData>>(new Map())
  const [ids, setIds] = useState<string[]>([])
  const [status, setStatus] = useState<Record<string, RdeResultRow>>({})
  const [restored, setRestored] = useState(0)
  const [confirmClear, setConfirmClear] = useState(false)
  const [showFees, setShowFees] = useState(() => {
    try { return localStorage.getItem('rde.grid.fees') === '1' } catch { return false }
  })
  const [portal, setPortal] = useState<{ created: number; reused: number; failed: number; note?: string } | null>(null)
  /* What has gone in this sitting, kept after the rows leave the grid: the
     names, the money recorded, and anything that did not go in. A saved row
     used to vanish with only a count left behind, and a fee step that failed
     vanished with it although the banner said "the message is on the row". */
  const [saved, setSaved] = useState<RdeResultRow[]>([])
  const [editing, setEditing] = useState<string | null>(null)
  /** Re-renders a Dues cell after its editor closes, the only time it changes. */
  const [, setDuesTick] = useState(0)
  const gridRef = useRef<HTMLTableSectionElement>(null)

  useEffect(() => {
    try { localStorage.setItem('rde.grid.fees', showFees ? '1' : '0') } catch { /* ignore */ }
  }, [showFees])

  /* WHAT THE SECTION ALREADY HOLDS. The grid used to open on an empty Roll
     column against a class that might already have twenty-three children in it,
     and nothing in the schema forbids two children on roll 1. */
  const roll = useQuery({
    queryKey: ['rollState', sessionId, classId, sectionId],
    queryFn: () => getSectionRollState(sessionId, classId, sectionId || null),
    enabled: !!sessionId && !!classId,
  })

  /* The class's monthly fee, which a ticked month of dues is filled with. */
  const fee = useQuery({
    queryKey: ['feeStructure', sessionId, classId],
    queryFn: () => getFeeStructure(sessionId, classId),
    enabled: !!sessionId && !!classId && showFees,
  })
  const monthlyFee = useMemo(
    () => (fee.data ? fee.data.filter((r) => r.is_recurring).reduce((s, r) => s + Number(r.amount ?? 0), 0) : null),
    [fee.data],
  )

  const cols = useMemo(() => COLS.filter((c) => !c.fee || showFees), [showFees])

  // ---- restore, once, before anything is typed ---------------------------
  useEffect(() => {
    let rows: RowData[] = []
    try {
      const raw = localStorage.getItem(cacheKey)
      if (raw) rows = JSON.parse(raw) as RowData[]
    } catch { /* private window, blocked storage: start empty rather than throw */ }
    const live = rows.filter((r) => r && typeof r === 'object' && !isBlank(r))
    // A draft kept before the per-row dues: its "Owes Rs" was for the newest
    // finished month, which is what saving it then would have recorded.
    const lastMonth = dueMonths()[0]
    for (const r of live) {
      const owes = parseAmount(r.arrears)
      if (owes && !Number.isNaN(owes) && !(r.dues ?? '').trim()) {
        r.dues = encodeDues({ months: { [lastMonth]: String(owes) }, named: [] })
      }
      delete r.arrears
    }
    const next: string[] = []
    store.current = new Map()
    for (const r of live) { const id = newId(); store.current.set(id, r); next.push(id) }
    // Always leave one blank row waiting at the bottom.
    for (let i = live.length; i < Math.max(live.length + 1, 12); i++) {
      const id = newId(); store.current.set(id, {}); next.push(id)
    }
    setIds(next)
    setStatus({})
    setRestored(live.length)
    if (live.some(hasFees)) setShowFees(true)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cacheKey])

  /* FILL THE ROLL COLUMN IN BEFORE ANYBODY TYPES, with the numbers this section
     has NOT used. Only the rows whose roll is still empty: a restored sitting
     keeps whatever was typed, and a roll the clerk wrote over is theirs. */
  useEffect(() => {
    if (!roll.data || ids.length === 0) return
    const blanks = ids.filter((id) => !(store.current.get(id)?.roll_no ?? '').trim())
    if (blanks.length === 0) return
    // Anything already typed into the grid counts as taken too, or two rows in
    // the same sitting would be handed the same number.
    const inGrid = ids
      .map((id) => Number((store.current.get(id)?.roll_no ?? '').replace(/\D/g, '')))
      .filter((n) => n > 0)
    const free = freeRolls([...roll.data.taken, ...inGrid], blanks.length)
    blanks.forEach((id, i) => {
      if (free[i] === undefined) return
      const r = store.current.get(id) ?? {}
      r.roll_no = String(free[i])
      store.current.set(id, r)
      const el = gridRef.current?.querySelector<HTMLInputElement>(`[data-cell="${id}:roll_no"]`)
      if (el && !el.value) el.value = String(free[i])
    })
    // Not persisted: a roll on its own is not typing (see isBlank).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roll.data, ids])

  // ---- autosave, debounced ------------------------------------------------
  const flush = useRef<number | undefined>(undefined)
  const persist = useCallback(() => {
    window.clearTimeout(flush.current)
    flush.current = window.setTimeout(() => {
      try {
        const rows = ids.map((id) => store.current.get(id) ?? {}).filter((r) => !isBlank(r))
        if (rows.length === 0) localStorage.removeItem(cacheKey)
        else localStorage.setItem(cacheKey, JSON.stringify(rows))
      } catch { /* storage full or blocked: the grid still works, it just forgets */ }
    }, 600)
  }, [ids, cacheKey])

  // A last write on unmount, so leaving the tab cannot lose the last 600ms.
  useEffect(() => () => {
    window.clearTimeout(flush.current)
    try {
      const rows = ids.map((id) => store.current.get(id) ?? {}).filter((r) => !isBlank(r))
      // Never a removal here. This cleanup also runs when the restored rows
      // first arrive, holding the empty list from before them, and removing
      // then would throw the sitting away the moment it came back. Emptying
      // the store is the debounced write's job and Clear's.
      if (rows.length > 0) localStorage.setItem(cacheKey, JSON.stringify(rows))
    } catch { /* ignore */ }
  }, [ids, cacheKey])

  function set(id: string, key: Field, v: string) {
    const r = store.current.get(id) ?? {}
    r[key] = v
    store.current.set(id, r)
    persist()
  }

  function addRow(after?: string) {
    const id = newId()
    store.current.set(id, {})
    setIds((prev) => {
      if (!after) return [...prev, id]
      const i = prev.indexOf(after)
      return i < 0 ? [...prev, id] : [...prev.slice(0, i + 1), id, ...prev.slice(i + 1)]
    })
    return id
  }

  /** Move focus by row/column offset, the way a spreadsheet does. */
  function move(rowId: string, key: Field, dRow: number, dCol: number) {
    const ci = cols.findIndex((c) => c.key === key) + dCol
    const ri = ids.indexOf(rowId) + dRow
    if (ci < 0 || ci >= cols.length || ri < 0 || ri >= ids.length) return false
    const sel = `[data-cell="${ids[ri]}:${cols[ci].key}"]`
    const el = gridRef.current?.querySelector<HTMLElement>(sel)
    if (!el) return false
    el.focus()
    if (el instanceof HTMLInputElement) el.select()
    return true
  }

  function onKeyDown(e: React.KeyboardEvent, rowId: string, key: Field) {
    const last = ids[ids.length - 1]
    const lastCol = cols[cols.length - 1].key
    if (e.key === 'Tab' && !e.shiftKey && rowId === last && key === lastCol) {
      // THE ONE THAT MATTERS: no reaching for a button, ever.
      e.preventDefault()
      const id = addRow()
      requestAnimationFrame(() => {
        gridRef.current
          ?.querySelector<HTMLElement>(`[data-cell="${id}:${cols[0].key}"]`)
          ?.focus()
      })
      return
    }
    if (e.key === 'Enter') {
      e.preventDefault()
      // On the Dues cell Enter opens the editor; everywhere else it moves down.
      if (key === 'dues') { setEditing(rowId); return }
      if (!move(rowId, key, 1, 0) && rowId === last) {
        const id = addRow()
        requestAnimationFrame(() => {
          gridRef.current
            ?.querySelector<HTMLElement>(`[data-cell="${id}:${key}"]`)
            ?.focus()
        })
      }
      return
    }
    if (e.key === 'ArrowDown') { if (move(rowId, key, 1, 0)) e.preventDefault(); return }
    if (e.key === 'ArrowUp')   { if (move(rowId, key, -1, 0)) e.preventDefault() }
  }

  /* A RETRY IS THE SAME SAVE. Each block of up to 200 rows carries a request
     id, kept while the rows are unchanged, so if the answer to a save is lost
     on a weak line and the clerk presses Save again, the server answers with
     the first save's result instead of admitting the class a second time. */
  const lastTry = useRef<{ sig: string; ids: string[] } | null>(null)

  // ---- saving -------------------------------------------------------------
  const save = useMutation({
    mutationFn: async () => {
      const payload: { id: string; row: RdeRow }[] = []
      const local: Record<string, RdeResultRow> = {}
      /* TWO CHILDREN ON ONE ROLL is the quiet disaster: nothing in the schema
         forbids it, so nothing else would ever say so. A roll already used in
         this section, or used twice in this grid, is stopped here. */
      const taken = new Set((roll.data?.taken ?? []).map(String))
      const seenRoll = new Map<string, number>()
      for (const id of ids) {
        const r = store.current.get(id) ?? {}
        if (isBlank(r)) continue
        const name = (r.full_name ?? '').trim()
        const problems: string[] = []
        if (!name) problems.push('Type a name for this row, or clear it.')
        const rn = (r.roll_no ?? '').trim()
        if (rn) {
          const key = String(Number(rn.replace(/\D/g, '')) || rn)
          if (taken.has(key)) problems.push(`Roll ${rn} is already used in this section.`)
          else if (seenRoll.has(key)) problems.push(`Roll ${rn} is also on row ${seenRoll.get(key)} of this grid.`)
          else seenRoll.set(key, ids.indexOf(id) + 1)
        }
        const discRaw = (r.discount ?? '').replace(/%/g, '')
        const disc = parseAmount(discRaw)
        if (disc !== null && (Number.isNaN(disc) || disc > 100)) {
          problems.push(`"${r.discount}" is not a concession: type a percentage, 1 to 100.`)
        }
        const dob = parseLooseDate(r.dob)
        if ((r.dob ?? '').trim() && !dob) problems.push(`"${r.dob}" is not a date: type it as dd/mm/yyyy.`)
        const dues = checkDues(decodeDues(r.dues), fmtMonth)
        problems.push(...dues.problems)
        if (problems.length > 0) {
          local[id] = { row: 0, status: 'error', full_name: name || 'A row with no name', message: problems.join(' ') }
          continue
        }
        payload.push({
          id,
          row: {
            full_name: name,
            roll_no: (r.roll_no ?? '').trim() || null,
            gr_no: (r.gr_no ?? '').trim() || null,
            father_name: (r.father_name ?? '').trim() || null,
            mother_name: (r.mother_name ?? '').trim() || null,
            gender: (r.gender ?? '') || null,
            dob,
            whatsapp: (r.whatsapp ?? '').trim() || null,
            father_cnic: (r.father_cnic ?? '').trim() || null,
            // THE MONEY. Sent only when the clerk actually filled it: an empty
            // cell must not become a zero-rupee concession or a due of nothing.
            paid_this_month: (r.paid ?? '') === 'y',
            discount: disc && disc > 0
              ? { type: 'other', amount: disc, is_percent: true, reason: 'entered at onboarding' }
              : null,
            dues: dues.dues.length > 0 ? dues.dues : null,
          },
        })
      }
      if (payload.length === 0 && Object.keys(local).length === 0) {
        throw new Error('Nothing to save yet. Type at least one name.')
      }

      const chunks: { id: string; row: RdeRow }[][] = []
      for (let i = 0; i < payload.length; i += CHUNK) chunks.push(payload.slice(i, i + CHUNK))
      const sig = JSON.stringify([classId, sectionId, payload.map((p) => p.row)])
      if (!lastTry.current || lastTry.current.sig !== sig) {
        lastTry.current = { sig, ids: chunks.map(() => newRequestId()) }
      }
      const byId: Record<string, RdeResultRow> = { ...local }
      let created = 0
      let drafts = 0
      for (let c = 0; c < chunks.length; c++) {
        const res = await rdeAddStudents({
          sessionId, classId, sectionId: sectionId || null,
          rows: chunks[c].map((p) => p.row), requestId: lastTry.current.ids[c],
        })
        created += res.created
        drafts += res.drafts
        // MAPPED BY THE ROW NUMBER THE SERVER GIVES, not by position: the
        // server numbers the rows it was sent and skips a row with no name
        // without answering for it, so position is only right by luck.
        for (const r of res.results) {
          const p = chunks[c][r.row - 1]
          if (p) byId[p.id] = r
        }
      }
      lastTry.current = null
      return { byId, created, drafts }
    },
    onSuccess: ({ byId }) => {
      setStatus(byId)
      const went = Object.values(byId).filter((r) => r.status !== 'error')
      if (went.length > 0) setSaved((s) => [...went, ...s].slice(0, 300))

      // Saved rows leave the grid, partial ones too: the child IS on the
      // roster, and a second press must not enter them twice. Failed ones stay,
      // with their reason, so the clerk fixes two lines instead of a hundred.
      const keep = ids.filter((id) => !byId[id] || byId[id].status === 'error')
      for (const id of ids) if (!keep.includes(id)) store.current.delete(id)
      const next = keep.length > 0 ? keep : [newId()]
      if (keep.length === 0) store.current.set(next[0], {})
      // Always a blank line waiting.
      const lastData = store.current.get(next[next.length - 1]) ?? {}
      if (!isBlank(lastData)) { const id = newId(); store.current.set(id, {}); next.push(id) }
      setIds(next)
      setRestored(0)
      persist()
      qc.invalidateQueries({ queryKey: ['studentPage'] })
      qc.invalidateQueries({ queryKey: ['draftStudents'] })
      qc.invalidateQueries({ queryKey: ['dashboardSummary'] })
      qc.invalidateQueries({ queryKey: ['rollState'] })
      qc.invalidateQueries({ queryKey: ['keyRing'] })
      for (const k of ['feesMonth', 'feesMonthPupils', 'arrears', 'familySheet', 'defaulters', 'billingCalendar']) {
        qc.invalidateQueries({ queryKey: [k] })
      }

      /* EVERY FAMILY IN THE CLASS GETS A LOGIN, IN ONE ROUND TRIP, without
         anybody pressing anything per child. NEVER ALLOWED TO THROW: the
         children are already saved. */
      void (async () => {
        const ids2 = went.filter((r) => r.student_id).map((r) => r.student_id as string)
        if (ids2.length === 0) return
        try {
          const targets = await listPortalTargets(ids2)
          if (targets.length === 0) return
          const made = await createFamilyPortals(targets)
          setPortal({ created: made.created, reused: made.reused, failed: made.failed, note: made.unavailable })
        } catch (e) {
          setPortal({ created: 0, reused: 0, failed: 1, note: (e as Error).message })
        }
      })()
    },
  })

  function clearAll() {
    store.current = new Map()
    const fresh = Array.from({ length: 12 }, () => { const id = newId(); store.current.set(id, {}); return id })
    setIds(fresh)
    setStatus({})
    setRestored(0)
    lastTry.current = null
    try { localStorage.removeItem(cacheKey) } catch { /* ignore */ }
    setConfirmClear(false)
  }

  /* NO LIVE COUNT ON THE BUTTON, on purpose. Reading how many names are typed
     means reading the ref, and making the button show it means re-rendering on
     every keystroke, which is the one thing this grid exists to avoid. */
  const failed = Object.values(status).filter((s) => s.status === 'error')
  const lastRun = save.data
  const partial = saved.filter((s) => s.status === 'partial')
  const hiddenMoney = !showFees ? ids.filter((id) => hasFees(store.current.get(id) ?? {})).length : 0
  const editingRow = editing ? store.current.get(editing) ?? {} : null

  return (
    <Card>
      <CardTitle icon={<IconStudents />}>
        {className}{sectionName ? ` · ${sectionName}` : ''}
      </CardTitle>

      {/* ------------------------------------------------- what is in there -- */}
      <div className="mb-3 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-lg bg-slate-100 px-3 py-2 text-xs text-slate-600">
        {roll.data ? (
          <span>
            Already on this list:{' '}
            <span className="font-semibold text-slate-800">{roll.data.on_roll}</span>
            {roll.data.taken.length > 0
              ? `, on rolls ${roll.data.taken[0]} to ${roll.data.taken[roll.data.taken.length - 1]}`
              : ''}
            . The Roll column below is filled with numbers nobody has used.
            {roll.data.unnumbered > 0 && (
              <span className="text-amber-700">
                {' '}({roll.data.unnumbered} roll{roll.data.unnumbered === 1 ? '' : 's'} with no
                number in {roll.data.unnumbered === 1 ? 'it' : 'them'}, so check those by hand.)
              </span>
            )}
          </span>
        ) : <span>Reading the class list…</span>}

        <label className="ml-auto flex items-center gap-1.5">
          <input type="checkbox" checked={showFees} onChange={(e) => setShowFees(e.target.checked)} />
          Enter fees and previous dues as I go
        </label>
      </div>

      {showFees && (
        <p className="mb-3 text-xs text-slate-500">
          <span className="font-medium text-slate-700">Paid</span> means this month&rsquo;s fee is already
          collected. <span className="font-medium text-slate-700">Previous dues</span> opens a box for the
          months and anything else the child already owed: press Enter on it, or click it.
          {monthlyFee != null && monthlyFee > 0 && <> This class pays Rs {fmtAmount(monthlyFee)} a month.</>}
        </p>
      )}
      {hiddenMoney > 0 && (
        <p className="mb-3 rounded-lg bg-due-50 px-3 py-2 text-xs text-due-800">
          {hiddenMoney} row{hiddenMoney === 1 ? ' has' : 's have'} fees or dues typed in that are hidden
          now. They will still be saved.{' '}
          <button type="button" onClick={() => setShowFees(true)} className="font-medium underline">Show them</button>
        </p>
      )}

      {portal && (
        <p className={`mb-3 rounded-lg px-3 py-2 text-xs ${
          portal.note ? 'bg-amber-50 text-amber-800' : 'bg-money-50 text-money-800'}`}>
          {portal.note ? portal.note : (
            <>
              {portal.created > 0 && <>{portal.created} parent portal login{portal.created === 1 ? '' : 's'} created. </>}
              {portal.reused > 0 && <>{portal.reused} child{portal.reused === 1 ? '' : 'ren'} joined a login their family already had. </>}
              {portal.failed > 0 && <span className="text-danger-700">
                {portal.failed} could not be made: give those families a login from the child&rsquo;s page.
              </span>}
              {portal.created > 0 && <span className="text-money-700">
                The addresses and passwords are on the key ring under Settings, Users.
              </span>}
            </>
          )}
        </p>
      )}

      {restored > 0 && (
        <p className="mb-3 rounded-lg bg-info-50 px-3 py-2 text-xs text-info-800">
          {restored} row{restored === 1 ? '' : 's'} came back from your last sitting on this class.
          Nothing was lost when the page closed.
        </p>
      )}

      <div className="-mx-4 overflow-x-auto sm:mx-0">
        <table className="min-w-full border-separate border-spacing-0 text-sm">
          <thead>
            <tr>
              <th className="sticky left-0 z-20 w-10 min-w-[2.5rem] bg-white px-2 py-1.5 text-left text-xs font-medium uppercase tracking-wide text-slate-400">
                #
              </th>
              {cols.map((c) => (
                <th key={c.key} title={c.title}
                  className={`border-b border-slate-200 bg-white px-1 py-1.5 text-left text-xs font-medium uppercase tracking-wide text-slate-500 ${
                    c.key === 'full_name' ? 'md:sticky md:left-10 md:z-20' : ''}`}>
                  {c.label}
                </th>
              ))}
              <th className="border-b border-slate-200 px-2 py-1.5" />
            </tr>
          </thead>
          <tbody ref={gridRef}>
            {ids.map((id, i) => {
              const st = status[id]
              const bad = st?.status === 'error'
              const rowBg = bad ? 'bg-danger-50' : 'bg-white'
              const r = store.current.get(id) ?? {}
              return [
                <tr key={id}>
                  <td className={`sticky left-0 z-10 w-10 min-w-[2.5rem] ${rowBg} px-2 py-0.5 text-xs tabular-nums text-slate-400`}>
                    {i + 1}
                  </td>
                  {cols.map((c) => (
                    <td key={c.key} className={`${rowBg} px-0.5 py-0.5 ${
                      c.key === 'full_name' ? 'md:sticky md:left-10 md:z-10' : ''}`}>
                      {c.kind === 'check' ? (
                        <input
                          type="checkbox"
                          data-cell={`${id}:${c.key}`}
                          aria-label={`Row ${i + 1}: this month's fee already collected`}
                          defaultChecked={(r[c.key] ?? '') === 'y'}
                          onChange={(e) => set(id, c.key, e.target.checked ? 'y' : '')}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                          className="mx-2 h-4 w-4"
                        />
                      ) : c.kind === 'dues' ? (
                        <DuesCell
                          id={id} row={i + 1} raw={r.dues}
                          onOpen={() => setEditing(id)}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                        />
                      ) : c.kind === 'select' ? (
                        <select
                          data-cell={`${id}:${c.key}`}
                          aria-label={`Row ${i + 1}: ${c.label}`}
                          defaultValue={r[c.key] ?? ''}
                          onChange={(e) => set(id, c.key, e.target.value)}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                          className={`${c.width} rounded border border-slate-200 bg-white px-1.5 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500`}
                        >
                          <option value="">-</option>
                          <option value="male">M</option>
                          <option value="female">F</option>
                          <option value="other">O</option>
                        </select>
                      ) : (
                        <input
                          data-cell={`${id}:${c.key}`}
                          aria-label={`Row ${i + 1}: ${c.label}`}
                          defaultValue={r[c.key] ?? ''}
                          inputMode={c.kind === 'num' ? 'numeric' : undefined}
                          onChange={(e) => set(id, c.key, e.target.value)}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                          className={`${c.width} rounded border border-slate-200 bg-white px-1.5 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500`}
                        />
                      )}
                    </td>
                  ))}
                  <td className={`${rowBg} px-2 py-0.5 text-xs`}>
                    {bad && <span className="text-danger-600" aria-hidden="true"><IconAlert /></span>}
                  </td>
                </tr>,
                // THE REASON UNDER THE ROW, not in a cell beyond the last column
                // where nobody scrolling a phone would ever reach it.
                bad && (
                  <tr key={`${id}-why`}>
                    <td className="sticky left-0 bg-danger-50" />
                    <td colSpan={cols.length + 1} className="bg-danger-50 px-1.5 pb-1.5 text-xs text-danger-700">
                      {st.message}
                    </td>
                  </tr>
                ),
              ]
            })}
          </tbody>
        </table>
      </div>

      <div className="mt-3 flex flex-wrap items-center gap-3">
        <Button onClick={() => save.mutate()} disabled={save.isPending} icon={<IconCheck />}>
          {save.isPending ? 'Saving…' : 'Save this class'}
        </Button>
        <button onClick={() => addRow()} className="text-sm text-brand-700 hover:underline">
          Add a row
        </button>
        <button onClick={() => setConfirmClear(true)} className="text-sm text-slate-500 hover:underline">
          Clear the grid
        </button>
        <span className="text-xs text-slate-400">
          Tab moves across, Enter moves down, and Tab on the last box makes a new row.
          Your typing is kept even if the page is closed.
        </span>
      </div>

      {save.isError && (
        <p className="mt-2 flex items-start gap-1.5 text-sm text-danger-600">
          <IconAlert />
          <span>
            {(save.error as Error).message}
            {lastTry.current && (
              <> Press Save again: anybody the first try already saved will not be entered twice.</>
            )}
          </span>
        </p>
      )}

      {lastRun && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50/70 px-3 py-2 text-sm">
          <span className="font-medium text-money-800">{lastRun.created} saved</span>
          {lastRun.drafts > 0 && (
            <span className="text-slate-500">
              {' · '}{lastRun.drafts} as draft{lastRun.drafts === 1 ? '' : 's'}
            </span>
          )}
          {failed.length > 0 && (
            <span className="text-danger-700">
              {' · '}{failed.length} still to fix, left in the grid above
            </span>
          )}
        </div>
      )}

      {/* ------------------------------------- what went in, and what did not -- */}
      {partial.length > 0 && (
        <div className="mt-3 rounded-lg border border-due-200 bg-due-50 px-3 py-2">
          <p className="text-sm font-medium text-due-900">
            Saved, but something did not go in for {partial.length} child{partial.length === 1 ? '' : 'ren'}
          </p>
          <ul className="mt-1 space-y-1 text-xs text-due-900">
            {partial.map((p) => (
              <li key={p.student_id ?? p.full_name}>
                {p.student_id
                  ? <Link to={`/students?student=${p.student_id}&tab=fees`} className="font-medium underline">{p.full_name}</Link>
                  : <span className="font-medium">{p.full_name}</span>}
                : {p.message}
              </li>
            ))}
          </ul>
        </div>
      )}
      {saved.length > 0 && (
        <details className="mt-3 rounded-lg border border-slate-200 px-3 py-2 text-sm">
          <summary className="cursor-pointer text-slate-700">
            Saved in this sitting: {saved.length}
            {saved.some((s) => (s.dues_total ?? 0) > 0) && (
              <span className="text-slate-500">
                {' · '}Rs {fmtAmount(saved.reduce((t, s) => t + Number(s.dues_total ?? 0), 0))} previous dues recorded
              </span>
            )}
          </summary>
          <ul className="mt-2 max-h-72 divide-y divide-slate-100 overflow-y-auto">
            {saved.map((s, i) => (
              <li key={`${s.student_id ?? s.full_name}-${i}`} className="flex flex-wrap items-center justify-between gap-2 py-1">
                <span className="min-w-0">
                  {s.student_id
                    ? <Link to={`/students?student=${s.student_id}`} className="text-slate-800 hover:underline">{s.full_name}</Link>
                    : s.full_name}
                  {s.gr_no && <span className="text-xs text-slate-400"> · {grLabel(s.gr_no)}</span>}
                  {(s.dues_total ?? 0) > 0 && (
                    <span className="text-xs text-slate-500"> · dues Rs {fmtAmount(s.dues_total)}</span>
                  )}
                  {(s.paid_amount ?? 0) > 0 && (
                    <span className="text-xs text-slate-500"> · paid Rs {fmtAmount(s.paid_amount)}</span>
                  )}
                </span>
                {s.status === 'partial' ? <Badge tone="due">check</Badge>
                  : s.is_draft ? <Badge tone="due">draft</Badge> : <Badge tone="money">ok</Badge>}
              </li>
            ))}
          </ul>
        </details>
      )}

      {saved.some((s) => s.is_draft) && (
        <p className="mt-2 text-xs text-slate-500">
          <Badge tone="due">draft</Badge>{' '}
          Rows saved without a father&rsquo;s name, gender, date of birth or a phone number are
          tagged for the dashboard reminder. They are billed and registered like everybody else.
        </p>
      )}

      {editing && editingRow && (
        <DuesDialog
          title={`Previous dues${(editingRow.full_name ?? '').trim() ? ` for ${editingRow.full_name?.trim()}` : `, row ${ids.indexOf(editing) + 1}`}`}
          intro={<>What this child already owed before today. Saved with the child when you save the class.</>}
          initial={decodeDues(editingRow.dues)}
          sessionStart={sessionStart}
          monthlyFee={monthlyFee}
          confirmLabel="Done"
          onCancel={() => {
            const at = editing
            setEditing(null)
            requestAnimationFrame(() => gridRef.current?.querySelector<HTMLElement>(`[data-cell="${at}:dues"]`)?.focus())
          }}
          onSubmit={(d) => {
            const at = editing
            set(at, 'dues', encodeDues(d))
            setEditing(null)
            setDuesTick((t) => t + 1)
            requestAnimationFrame(() => gridRef.current?.querySelector<HTMLElement>(`[data-cell="${at}:dues"]`)?.focus())
          }}
        />
      )}

      {confirmClear && (
        <AskDialog
          title="Clear the grid?"
          intro={
            <>
              This throws away everything typed here that has not been saved, including the rows
              that came back from your last sitting. Children already saved are not touched.
            </>
          }
          confirmLabel="Clear it"
          tone="danger"
          onCancel={() => setConfirmClear(false)}
          onSubmit={clearAll}
        />
      )}
    </Card>
  )
}

/** One row's previous dues, as a button: "Add", or what is owed. */
function DuesCell({ id, row, raw, onOpen, onKeyDown }: {
  id: string; row: number; raw: string | undefined
  onOpen: () => void
  onKeyDown: (e: React.KeyboardEvent) => void
}) {
  const d = decodeDues(raw)
  const c = checkDues(d)
  const empty = isDuesEmpty(d)
  const bad = !empty && c.problems.length > 0
  const items = c.months + c.named
  const full = empty ? 'none' : bad ? 'something to check' : duesSummary(c)
  return (
    <button
      type="button" data-cell={`${id}:dues`} onClick={onOpen} onKeyDown={onKeyDown}
      aria-label={`Row ${row}: previous dues, ${full}`}
      title={empty ? 'Add previous dues' : full}
      className={`flex w-36 items-center justify-between gap-1 rounded border px-1.5 py-1 text-left text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 ${
        empty ? 'border-dashed border-slate-300 text-slate-400 hover:text-brand-700'
          : bad ? 'border-danger-300 bg-danger-50 text-danger-700'
            : 'border-due-200 bg-due-50 text-due-800'}`}
    >
      {empty ? 'Add' : bad ? 'Check' : (
        <>
          <span className="font-semibold tabular-nums">Rs {Math.round(c.total).toLocaleString('en-PK')}</span>
          <span className="shrink-0 text-[11px] text-due-700">{items} item{items === 1 ? '' : 's'}</span>
        </>
      )}
    </button>
  )
}

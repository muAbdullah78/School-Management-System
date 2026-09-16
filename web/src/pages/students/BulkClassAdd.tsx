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
 */
import { useCallback, useEffect, useRef, useState } from 'react'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { rdeAddStudents, type RdeRow, type RdeResultRow } from '@/lib/db'
import { Card, CardTitle, Button, Badge } from '@/components/ui'
import { IconStudents, IconCheck, IconAlert } from '@/components/icons'
import { AskDialog } from '@/components/AskDialog'

type Field =
  | 'roll_no' | 'full_name' | 'father_name' | 'mother_name'
  | 'gender' | 'dob' | 'whatsapp' | 'father_cnic' | 'gr_no'

const COLS: { key: Field; label: string; width: string; kind?: 'select' | 'num' }[] = [
  { key: 'roll_no',     label: 'Roll',            width: 'w-16',  kind: 'num' },
  { key: 'full_name',   label: 'Name',            width: 'w-52' },
  { key: 'father_name', label: 'Father',          width: 'w-44' },
  { key: 'mother_name', label: 'Mother',          width: 'w-40' },
  { key: 'gender',      label: 'M/F',             width: 'w-20',  kind: 'select' },
  { key: 'dob',         label: 'DOB dd/mm/yyyy',  width: 'w-32' },
  { key: 'whatsapp',    label: 'WhatsApp',        width: 'w-36',  kind: 'num' },
  { key: 'father_cnic', label: 'Father CNIC',     width: 'w-40',  kind: 'num' },
  { key: 'gr_no',       label: 'GR',              width: 'w-24' },
]

type RowData = Partial<Record<Field, string>>

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

/** Blank row: nothing typed anywhere. Saved rows never include one. */
function isBlank(r: RowData): boolean {
  return !Object.values(r).some((v) => (v ?? '').trim().length > 0)
}

let seq = 0
const newId = () => `r${++seq}`

export function BulkClassAdd({
  sessionId, classId, sectionId, className, sectionName,
}: {
  sessionId: string; classId: string; sectionId: string
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
  const gridRef = useRef<HTMLTableSectionElement>(null)

  // ---- restore, once, before anything is typed ---------------------------
  useEffect(() => {
    let rows: RowData[] = []
    try {
      const raw = localStorage.getItem(cacheKey)
      if (raw) rows = JSON.parse(raw) as RowData[]
    } catch { /* private window, blocked storage: start empty rather than throw */ }
    const live = rows.filter((r) => !isBlank(r))
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
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cacheKey])

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
    const ci = COLS.findIndex((c) => c.key === key) + dCol
    const ri = ids.indexOf(rowId) + dRow
    if (ci < 0 || ci >= COLS.length || ri < 0 || ri >= ids.length) return false
    const sel = `[data-cell="${ids[ri]}:${COLS[ci].key}"]`
    const el = gridRef.current?.querySelector<HTMLElement>(sel)
    if (!el) return false
    el.focus()
    if (el instanceof HTMLInputElement) el.select()
    return true
  }

  function onKeyDown(e: React.KeyboardEvent, rowId: string, key: Field) {
    const last = ids[ids.length - 1]
    const lastCol = COLS[COLS.length - 1].key
    if (e.key === 'Tab' && !e.shiftKey && rowId === last && key === lastCol) {
      // THE ONE THAT MATTERS: no reaching for a button, ever.
      e.preventDefault()
      const id = addRow()
      requestAnimationFrame(() => {
        gridRef.current
          ?.querySelector<HTMLElement>(`[data-cell="${id}:${COLS[0].key}"]`)
          ?.focus()
      })
      return
    }
    if (e.key === 'Enter') {
      e.preventDefault()
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

  // ---- saving -------------------------------------------------------------
  const save = useMutation({
    mutationFn: async () => {
      const payload: { id: string; row: RdeRow }[] = []
      for (const id of ids) {
        const r = store.current.get(id) ?? {}
        if (isBlank(r) || !(r.full_name ?? '').trim()) continue
        // A row with detail but no name cannot be saved; it is reported below
        // rather than dropped silently.
        payload.push({
          id,
          row: {
            full_name: (r.full_name ?? '').trim(),
            roll_no: (r.roll_no ?? '').trim() || null,
            gr_no: (r.gr_no ?? '').trim() || null,
            father_name: (r.father_name ?? '').trim() || null,
            mother_name: (r.mother_name ?? '').trim() || null,
            gender: (r.gender ?? '') || null,
            dob: parseLooseDate(r.dob),
            whatsapp: (r.whatsapp ?? '').trim() || null,
            father_cnic: (r.father_cnic ?? '').trim() || null,
          },
        })
      }
      if (payload.length === 0) throw new Error('Nothing to save yet. Type at least one name.')
      const res = await rdeAddStudents({
        sessionId, classId, sectionId: sectionId || null, rows: payload.map((p) => p.row),
      })
      return { res, order: payload.map((p) => p.id) }
    },
    onSuccess: ({ res, order }) => {
      const byId: Record<string, RdeResultRow> = {}
      // fn_rde_add_students numbers rows over the list it was GIVEN and skips
      // nothing, so position maps straight back.
      res.results.forEach((r, i) => { const id = order[i]; if (id) byId[id] = r })
      setStatus(byId)

      // Saved rows leave the grid. Failed ones stay, with their reason, so the
      // clerk fixes two lines instead of hunting through a hundred, and a
      // second press cannot enter anybody twice.
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
    },
  })

  function clearAll() {
    store.current = new Map()
    const fresh = Array.from({ length: 12 }, () => { const id = newId(); store.current.set(id, {}); return id })
    setIds(fresh)
    setStatus({})
    setRestored(0)
    try { localStorage.removeItem(cacheKey) } catch { /* ignore */ }
    setConfirmClear(false)
  }

  /* NO LIVE COUNT ON THE BUTTON, on purpose. Reading how many names are typed
     means reading the ref, and making the button show it means re-rendering on
     every keystroke, which is the one thing this grid exists to avoid. The row
     numbers down the left already say how far the clerk has got, and the count
     that matters is the one in the result line after the save. */
  const failed = Object.values(status).filter((s) => s.status === 'error')

  return (
    <Card>
      <CardTitle icon={<IconStudents />}>
        {className}{sectionName ? ` · ${sectionName}` : ''}
      </CardTitle>

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
              <th className="sticky left-0 z-10 bg-white px-2 py-1.5 text-left text-xs font-medium uppercase tracking-wide text-slate-400">
                #
              </th>
              {COLS.map((c) => (
                <th key={c.key}
                  className="border-b border-slate-200 px-1 py-1.5 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  {c.label}
                </th>
              ))}
              <th className="border-b border-slate-200 px-2 py-1.5" />
            </tr>
          </thead>
          <tbody ref={gridRef}>
            {ids.map((id, i) => {
              const st = status[id]
              return (
                <tr key={id} className={st?.status === 'error' ? 'bg-danger-50/60' : undefined}>
                  <td className="sticky left-0 z-10 bg-inherit px-2 py-0.5 text-xs tabular-nums text-slate-400">
                    {i + 1}
                  </td>
                  {COLS.map((c) => (
                    <td key={c.key} className="px-0.5 py-0.5">
                      {c.kind === 'select' ? (
                        <select
                          data-cell={`${id}:${c.key}`}
                          defaultValue={store.current.get(id)?.[c.key] ?? ''}
                          onChange={(e) => set(id, c.key, e.target.value)}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                          className={`${c.width} rounded border border-slate-200 px-1.5 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500`}
                        >
                          <option value="">-</option>
                          <option value="male">M</option>
                          <option value="female">F</option>
                          <option value="other">O</option>
                        </select>
                      ) : (
                        <input
                          data-cell={`${id}:${c.key}`}
                          defaultValue={store.current.get(id)?.[c.key] ?? ''}
                          inputMode={c.kind === 'num' ? 'numeric' : undefined}
                          onChange={(e) => set(id, c.key, e.target.value)}
                          onKeyDown={(e) => onKeyDown(e, id, c.key)}
                          className={`${c.width} rounded border border-slate-200 px-1.5 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500`}
                        />
                      )}
                    </td>
                  ))}
                  <td className="whitespace-nowrap px-2 py-0.5 text-xs">
                    {st?.status === 'error' && (
                      <span className="text-danger-700">{st.message}</span>
                    )}
                  </td>
                </tr>
              )
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
          <IconAlert />{(save.error as Error).message}
        </p>
      )}

      {save.data && (
        <div className="mt-3 rounded-lg border border-slate-200 bg-slate-50/70 px-3 py-2 text-sm">
          <span className="font-medium text-money-800">{save.data.res.created} saved</span>
          {save.data.res.drafts > 0 && (
            <span className="text-slate-500">
              {' · '}{save.data.res.drafts} as draft{save.data.res.drafts === 1 ? '' : 's'}
            </span>
          )}
          {failed.length > 0 && (
            <span className="text-danger-700">
              {' · '}{failed.length} still to fix, left in the grid above
            </span>
          )}
          {save.data.res.results.some((r) => r.status === 'partial') && (
            <p className="mt-1 text-xs text-due-800">
              Some rows were admitted but a fee step did not run. They are on the roster; the
              message is on the row.
            </p>
          )}
        </div>
      )}

      {Object.values(status).some((s) => s.is_draft) && (
        <p className="mt-2 text-xs text-slate-500">
          <Badge tone="due">draft</Badge>{' '}
          Rows saved without a father&rsquo;s name, gender, date of birth or a phone number are
          tagged for the dashboard reminder. They are billed and registered like everybody else.
        </p>
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

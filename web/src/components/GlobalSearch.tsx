/**
 * The one search box, reachable from anywhere.
 *
 * Their header has "Search Student / Teacher / Parent here…" on every screen,
 * and it is the answer to the complaint that started this rebuild: that finding
 * anything meant first knowing which of twenty modules held it. A clerk with a
 * parent on the phone saying "I am Bilal's father" should not have to decide
 * whether that is a Students question, a Families question or a Fee question.
 *
 * What it searches, and what it will not show a given user, is decided in SQL
 * (fn_global_search). A class teacher finds pupils and not the receipt book.
 * Doing that here would be decoration over an open door.
 */
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { globalSearch, type SearchHit } from '@/lib/db'

const KIND_LABEL: Record<string, string> = {
  student: 'Student',
  staff: 'Staff',
  family: 'Family',
  challan: 'Challan',
  receipt: 'Receipt',
  enquiry: 'Enquiry',
}

const KIND_STYLE: Record<string, string> = {
  student: 'bg-brand-100 text-brand-800',
  staff: 'bg-violet-100 text-violet-800',
  family: 'bg-amber-100 text-amber-800',
  challan: 'bg-slate-200 text-slate-700',
  receipt: 'bg-money-100 text-money-800',
  enquiry: 'bg-sky-100 text-sky-800',
}

export function GlobalSearch() {
  const [term, setTerm] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const boxRef = useRef<HTMLDivElement>(null)
  const inputRef = useRef<HTMLInputElement>(null)
  const navigate = useNavigate()

  // Two characters is the floor in SQL as well; asking earlier just wastes a
  // round trip and makes the box feel like it is doing nothing.
  const enabled = term.trim().length >= 2
  const q = useQuery({
    queryKey: ['globalSearch', term.trim()],
    queryFn: () => globalSearch(term.trim()),
    enabled,
    staleTime: 15_000,
  })

  const hits = enabled ? (q.data ?? []) : []

  useEffect(() => setActive(0), [term])

  // Close on a click elsewhere. Without this the panel hangs over the page
  // after the user has moved on.
  useEffect(() => {
    function onDown(e: MouseEvent) {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [])

  // "/" focuses the box from anywhere, which is how anybody who uses a keyboard
  // expects a search to work, but not while they are typing in another field.
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const el = e.target as HTMLElement | null
      const typing = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' ||
                            el.tagName === 'SELECT' || el.isContentEditable)
      if (e.key === '/' && !typing) {
        e.preventDefault()
        inputRef.current?.focus()
      }
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  function go(hit: SearchHit) {
    setOpen(false)
    setTerm('')
    // The route comes from SQL, so this cannot drift from the list of things
    // that are searchable.
    navigate(hit.route)
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (!hits.length) return
    if (e.key === 'ArrowDown') { e.preventDefault(); setActive((i) => (i + 1) % hits.length) }
    if (e.key === 'ArrowUp') { e.preventDefault(); setActive((i) => (i - 1 + hits.length) % hits.length) }
    if (e.key === 'Enter') { e.preventDefault(); go(hits[active]) }
  }

  return (
    <div ref={boxRef} className="relative w-full max-w-md print:hidden">
      <input
        ref={inputRef}
        value={term}
        onChange={(e) => { setTerm(e.target.value); setOpen(true) }}
        onFocus={() => setOpen(true)}
        onKeyDown={onKeyDown}
        placeholder="Search a child, parent, teacher, challan or receipt…   /"
        aria-label="Search the school"
        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm placeholder:text-slate-400 focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
      />

      {open && enabled && (
        <div className="absolute z-50 mt-1 w-full overflow-hidden rounded-lg border border-slate-200 bg-white shadow-lg">
          {q.isLoading ? (
            <p className="px-3 py-3 text-sm text-slate-500">Searching…</p>
          ) : q.isError ? (
            <p className="px-3 py-3 text-sm text-danger-600">{(q.error as Error).message}</p>
          ) : hits.length === 0 ? (
            <div className="px-3 py-3 text-sm text-slate-500">
              Nothing found for &ldquo;{term.trim()}&rdquo;.
              <span className="mt-1 block text-xs text-slate-400">
                A name, a GR number, a phone number typed any way, a voucher code or a receipt
                number all work.
              </span>
            </div>
          ) : (
            <ul className="max-h-80 overflow-y-auto">
              {hits.map((h, i) => (
                <li key={`${h.kind}-${h.id}`}>
                  <button
                    type="button"
                    onMouseEnter={() => setActive(i)}
                    onClick={() => go(h)}
                    className={`flex w-full items-start gap-2 px-3 py-2 text-left text-sm ${
                      i === active ? 'bg-brand-50' : 'hover:bg-slate-50'}`}
                  >
                    <span className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium uppercase ${
                      KIND_STYLE[h.kind] ?? 'bg-slate-200 text-slate-700'}`}>
                      {KIND_LABEL[h.kind] ?? h.kind}
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-slate-800">{h.title}</span>
                      <span className="block truncate text-xs text-slate-500">
                        {h.subtitle}
                        {h.detail && <span className="text-slate-400"> · {h.detail}</span>}
                      </span>
                    </span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  )
}

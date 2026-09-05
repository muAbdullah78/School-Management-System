/**
 * The table component this product should have had from the start.
 *
 * There was no table primitive at all: 33 hand-rolled <table> elements across
 * 23 page files, no sortable column anywhere in the app, no pagination, no
 * zebra banding, no accessibility affordances, and the same list (defaulters)
 * implemented twice with different columns so the two screens gave different
 * answers to the same question.
 *
 * WHAT IS DELIBERATE HERE
 *
 * Sorting is client-side, over the rows currently loaded, and the component
 * SAYS SO when there are more rows than that. A table that silently sorts one
 * page of fifty and presents it as "sorted by highest balance" is the same
 * class of lie as a dashboard reporting Rs 0 owed because nothing was billed.
 * Either the caller loads the whole set, or the user is told what the sort
 * covers.
 *
 * Export writes the loaded rows, labelled as such, for the same reason.
 *
 * Every header carries scope="col" and aria-sort. The previous tables had 33
 * unlabelled cell grids of student and financial data.
 */
import { useMemo, useState, type ReactNode } from 'react'
import { toCSV, downloadCSV } from '@/lib/csv'

export interface Column<T> {
  /** Stable key, also used for the sort state. */
  key: string
  header: string
  /** Cell contents. Omit to render `String(row[key])`. */
  render?: (row: T) => ReactNode
  /** Value to sort and export by, when the rendered cell is not sortable text. */
  value?: (row: T) => string | number | null
  align?: 'left' | 'right'
  sortable?: boolean
  /** Hidden on narrow screens. For columns a phone does not need. */
  secondary?: boolean
}

const PAGE_SIZES = [25, 50, 100, 250]

/**
 * Compare two cell values for sorting.
 *
 * Exported because the null rule is the part worth testing: nulls sort LAST in
 * both directions. An empty cell is not "the smallest value". It is missing,
 * and burying the rows you asked to see under a pile of blanks is the usual way
 * a sortable table becomes useless. Numbers compare numerically; text uses a
 * numeric-aware locale compare so "Class 10" follows "Class 9".
 */
export function compareCells(
  x: string | number | null | undefined,
  y: string | number | null | undefined,
  dir: 'asc' | 'desc',
): number {
  if (x == null && y == null) return 0
  if (x == null) return 1
  if (y == null) return -1
  const c =
    typeof x === 'number' && typeof y === 'number'
      ? x - y
      : String(x).localeCompare(String(y), undefined, { numeric: true })
  return dir === 'asc' ? c : -c
}

export function DataTable<T>({
  rows,
  columns,
  rowKey,
  total,
  page,
  pageSize,
  onPageChange,
  onPageSizeChange,
  search,
  onSearchChange,
  searchPlaceholder = 'Search…',
  onRowClick,
  loading,
  error,
  emptyTitle = 'Nothing to show',
  emptyMessage,
  exportName,
  toolbarExtra,
  printId,
}: {
  rows: T[]
  columns: Column<T>[]
  rowKey: (row: T) => string
  /** Size of the whole filtered set. Omit when `rows` IS the whole set. */
  total?: number
  page?: number
  pageSize?: number
  onPageChange?: (page: number) => void
  onPageSizeChange?: (size: number) => void
  search?: string
  onSearchChange?: (v: string) => void
  searchPlaceholder?: string
  onRowClick?: (row: T) => void
  loading?: boolean
  error?: string | null
  emptyTitle?: string
  emptyMessage?: string
  /** Enables CSV export, and names the file. */
  exportName?: string
  toolbarExtra?: ReactNode
  /** Element id for the print stylesheet to target. */
  printId?: string
}) {
  const [sortKey, setSortKey] = useState<string | null>(null)
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc')

  const knownTotal = total ?? rows.length
  const partial = knownTotal > rows.length

  const sorted = useMemo(() => {
    if (!sortKey) return rows
    const col = columns.find((c) => c.key === sortKey)
    if (!col) return rows
    const get = (r: T) =>
      col.value ? col.value(r) : ((r as Record<string, unknown>)[col.key] as string | number | null)
    return [...rows].sort((a, b) => compareCells(get(a), get(b), sortDir))
  }, [rows, columns, sortKey, sortDir])

  function toggleSort(key: string) {
    if (sortKey === key) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
    else {
      setSortKey(key)
      setSortDir('asc')
    }
  }

  function exportCsv() {
    // lib/csv is used rather than a local escaper: downloadCSV prepends a UTF-8
    // BOM so Excel opens Urdu names correctly, which a hand-rolled version here
    // did not, and toCSV is already covered by tests.
    const csv = toCSV(
      columns.map((c) => c.header),
      sorted.map((r) =>
        columns.map((c) => {
          const v = c.value ? c.value(r) : (r as Record<string, unknown>)[c.key]
          return v == null ? '' : (v as string | number)
        }),
      ),
    )
    downloadCSV(`${exportName}.csv`, csv)
  }

  const from = page != null && pageSize != null ? page * pageSize + 1 : 1
  const to = page != null && pageSize != null ? Math.min((page + 1) * pageSize, knownTotal) : rows.length
  const lastPage = pageSize ? Math.max(0, Math.ceil(knownTotal / pageSize) - 1) : 0

  return (
    <div>
      {/* -------------------------------------------------------- toolbar -- */}
      <div className="mb-3 flex flex-wrap items-center gap-2 print:hidden">
        {onSearchChange && (
          <input
            value={search ?? ''}
            onChange={(e) => onSearchChange(e.target.value)}
            placeholder={searchPlaceholder}
            className="min-w-[14rem] flex-1 rounded border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none"
          />
        )}
        {toolbarExtra}
        {onPageSizeChange && (
          <select
            value={pageSize}
            onChange={(e) => onPageSizeChange(Number(e.target.value))}
            aria-label="Rows per page"
            className="rounded border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none"
          >
            {PAGE_SIZES.map((n) => (
              <option key={n} value={n}>
                {n} / page
              </option>
            ))}
          </select>
        )}
        {exportName && rows.length > 0 && (
          <button
            onClick={exportCsv}
            className="rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            CSV
          </button>
        )}
        {printId && rows.length > 0 && (
          <button
            onClick={() => window.print()}
            className="rounded border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Print
          </button>
        )}
      </div>

      {/* ---------------------------------------------------------- table -- */}
      <div id={printId} className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
        {loading && <div className="p-4 text-sm text-slate-400">Loading…</div>}
        {error && <div className="p-4 text-sm text-danger-600">{error}</div>}

        {!loading && !error && rows.length === 0 && (
          <div className="p-8 text-center">
            <div className="text-sm font-medium text-slate-600">{emptyTitle}</div>
            {emptyMessage && <div className="mt-1 text-sm text-slate-400">{emptyMessage}</div>}
          </div>
        )}

        {!loading && !error && rows.length > 0 && (
          <table className="min-w-full text-sm">
            <thead className="sticky top-0 z-10 bg-slate-50">
              <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                {columns.map((c) => {
                  const active = sortKey === c.key
                  return (
                    <th
                      key={c.key}
                      scope="col"
                      aria-sort={active ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none'}
                      className={`px-3 py-2 font-medium ${c.align === 'right' ? 'text-right' : ''} ${
                        c.secondary ? 'hidden sm:table-cell' : ''
                      }`}
                    >
                      {c.sortable ? (
                        <button
                          onClick={() => toggleSort(c.key)}
                          className="inline-flex items-center gap-1 uppercase tracking-wide hover:text-slate-800"
                        >
                          {c.header}
                          <span aria-hidden className={active ? 'text-brand-600' : 'text-slate-300'}>
                            {active ? (sortDir === 'asc' ? '▲' : '▼') : '↕'}
                          </span>
                        </button>
                      ) : (
                        c.header
                      )}
                    </th>
                  )
                })}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {sorted.map((r) => (
                <tr
                  key={rowKey(r)}
                  onClick={onRowClick ? () => onRowClick(r) : undefined}
                  onKeyDown={
                    onRowClick
                      ? (e) => {
                          if (e.key === 'Enter' || e.key === ' ') {
                            e.preventDefault()
                            onRowClick(r)
                          }
                        }
                      : undefined
                  }
                  tabIndex={onRowClick ? 0 : undefined}
                  className={`odd:bg-white even:bg-slate-50/40 ${
                    onRowClick
                      ? 'cursor-pointer hover:bg-brand-50/60 focus:bg-brand-50/60 focus:outline-none'
                      : ''
                  }`}
                >
                  {columns.map((c) => (
                    <td
                      key={c.key}
                      className={`px-3 py-2 ${c.align === 'right' ? 'text-right tabular-nums' : ''} ${
                        c.secondary ? 'hidden sm:table-cell' : ''
                      }`}
                    >
                      {c.render
                        ? c.render(r)
                        : String((r as Record<string, unknown>)[c.key] ?? '-')}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      {/* ------------------------------------------------------- footer -- */}
      {!loading && !error && rows.length > 0 && (
        <div className="mt-2 flex flex-wrap items-center gap-3 text-xs text-slate-500 print:hidden">
          <span>
            Showing {from} to {to} of {knownTotal}
          </span>

          {sortKey && partial && (
            // The honest caveat. Without it, "sorted by highest balance" over
            // one page of fifty out of eight hundred is simply false.
            <span className="text-amber-700">
              Sorted within these {rows.length} rows only: narrow the search or raise the page size
              to sort the whole list.
            </span>
          )}

          {exportName && partial && <span>CSV exports these {rows.length} rows.</span>}

          {onPageChange && pageSize != null && page != null && lastPage > 0 && (
            <span className="ml-auto flex items-center gap-1">
              <button
                onClick={() => onPageChange(Math.max(0, page - 1))}
                disabled={page === 0}
                className="rounded border border-slate-300 bg-white px-2 py-1 disabled:opacity-40"
              >
                ← Prev
              </button>
              <span className="px-1">
                {page + 1} / {lastPage + 1}
              </span>
              <button
                onClick={() => onPageChange(Math.min(lastPage, page + 1))}
                disabled={page >= lastPage}
                className="rounded border border-slate-300 bg-white px-2 py-1 disabled:opacity-40"
              >
                Next →
              </button>
            </span>
          )}
        </div>
      )}
    </div>
  )
}

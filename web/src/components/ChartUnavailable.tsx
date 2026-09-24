import { isMissingFunction } from '@/lib/notInstalled'

/**
 * What a chart says when it cannot draw.
 *
 * Two different facts, and they must not look alike. A function that is not
 * installed yet is an update somebody has not pasted: grey, calm, and it names
 * the bundle for whoever looks after the database. A read that failed is a
 * fault: red, with the database's own words, so it can be reported. Neither is
 * ever drawn as an empty chart, because an empty chart reads as "nothing
 * happened", which is the one thing it does not know.
 */
export function ChartUnavailable({
  error, what = 'The charts on this screen', bundle = 48, className = '',
}: {
  error: unknown
  what?: string
  bundle?: number
  className?: string
}) {
  const missing = isMissingFunction(error)
  return (
    <div
      role={missing ? 'note' : 'alert'}
      className={`rounded-2xl border p-4 text-sm ${
        missing ? 'border-slate-200 bg-white text-slate-600' : 'border-danger-200 bg-danger-50 text-danger-800'
      } ${className}`}
    >
      <p className={`font-medium ${missing ? 'text-slate-900' : 'text-danger-900'}`}>
        {missing ? `${what} are not switched on yet` : `${what} could not be loaded`}
      </p>
      <p className="mt-1">
        {missing
          ? 'They need a database update that has not been applied yet. Everything else here is live.'
          : `${(error as Error)?.message ?? 'Unknown error'}. Nothing else on this screen is affected.`}
      </p>
      {missing && (
        <p className="mt-1 text-xs text-slate-400">For whoever looks after the database: bundle {bundle}.</p>
      )}
    </div>
  )
}

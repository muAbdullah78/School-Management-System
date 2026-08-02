export function NotConfigured() {
  return (
    <div className="flex h-full items-center justify-center p-6">
      <div className="max-w-md rounded-lg bg-white p-6 shadow">
        <h1 className="text-lg font-semibold text-slate-800">App not configured yet</h1>
        <p className="mt-2 text-sm text-slate-600">
          This copy of School Manager has not been pointed at a Supabase project. Set{' '}
          <code className="rounded bg-slate-100 px-1">VITE_SUPABASE_URL</code> and{' '}
          <code className="rounded bg-slate-100 px-1">VITE_SUPABASE_ANON_KEY</code> (see{' '}
          <code className="rounded bg-slate-100 px-1">.env.example</code>) and rebuild.
        </p>
        <p className="mt-3 text-sm text-slate-500">
          The per-school setup steps are in <code className="rounded bg-slate-100 px-1">docs/SETUP-PER-SCHOOL.md</code>.
        </p>
      </div>
    </div>
  )
}

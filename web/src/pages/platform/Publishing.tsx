import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  announce, endAnnouncement, listAnnouncements, listReleases,
  publishRelease, unpublishRelease,
  type Announcement, type Audience, type Severity,
} from '@/lib/platform'
import { fmtDateTime } from '@/lib/format'

const FIELD = 'w-full rounded border border-slate-300 px-2 py-1.5 text-sm'

/**
 * What the schools and the public see: the installer, and notices.
 *
 * TWO THINGS JOINED UP HERE THAT WERE NEVER JOINED UP.
 *
 * The desktop build has always been a CI artifact. A GitHub login and a 90-day
 * expiry stand between a school and the file. So the one thing a Pakistani school
 * office actually asks for, "give me the installer for the front-desk computer",
 * could not be given. Publishing a release makes the website's download button
 * and the app's update prompt read the same row.
 *
 * And there has never been any way to tell every school anything. "Maintenance
 * on Sunday 6-7am" meant fifty WhatsApp messages, and the schools that most need
 * to know are the ones whose number is out of date.
 */
export function Publishing() {
  return (
    <div className="space-y-4">
      <Releases />
      <Announcements />
    </div>
  )
}

function Releases() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['releases'], queryFn: () => listReleases() })
  const [open, setOpen] = useState(false)
  const [platform, setPlatform] = useState('windows')
  const [version, setVersion] = useState('')
  const [url, setUrl] = useState('')
  const [sha, setSha] = useState('')
  const [notes, setNotes] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)

  const pub = useMutation({
    mutationFn: () => publishRelease({
      platform, version: version.trim(), url: url.trim(),
      sha256: sha.trim().toLowerCase(), notes: notes.trim() || null,
    }),
    onSuccess: (r) => {
      setErr(null); setMsg(`${r.version} is now the download on the website.`)
      setOpen(false); setVersion(''); setUrl(''); setSha(''); setNotes('')
      void qc.invalidateQueries({ queryKey: ['releases'] })
    },
    onError: (e) => { setMsg(null); setErr((e as Error).message) },
  })

  const pull = useMutation({
    mutationFn: (v: { id: string; reason: string }) => unpublishRelease(v.id, v.reason),
    onSuccess: (r) => {
      setErr(null); setMsg(r.note)
      void qc.invalidateQueries({ queryKey: ['releases'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  const rows = q.data ?? []
  const current = rows.filter((r) => r.is_current)

  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-800">The desktop installer</h2>
          <p className="mt-0.5 text-xs text-slate-500">
            What the website offers for download, and what the app checks against for
            updates. Both read the row marked current.
          </p>
        </div>
        <button onClick={() => { setOpen((v) => !v); setErr(null); setMsg(null) }}
          className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
          {open ? 'Cancel' : 'Publish a release'}
        </button>
      </div>

      {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}
      {msg && <p className="mt-3 rounded bg-emerald-50 px-3 py-2 text-sm text-emerald-800">{msg}</p>}

      {current.length === 0 && !q.isLoading && (
        <p className="mt-3 rounded border border-amber-300 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Nothing is published, so the website&rsquo;s download button says the installer is
          being prepared. Build it, upload the file somewhere schools can reach, and
          record it here.
        </p>
      )}

      {open && (
        <div className="mt-3 space-y-3 rounded border border-slate-200 bg-slate-50 p-3">
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">For</span>
              <select className={FIELD} value={platform}
                onChange={(e) => setPlatform(e.target.value)}>
                <option value="windows">Windows</option>
                <option value="mac">macOS</option>
                <option value="linux">Linux</option>
              </select>
            </label>
            <label className="block">
              <span className="text-xs font-medium text-slate-600">Version</span>
              <input className={FIELD} value={version} placeholder="1.4.2"
                onChange={(e) => setVersion(e.target.value)} />
            </label>
          </div>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Download link</span>
            <input className={FIELD} value={url} placeholder="https://…/SchoolManager-1.4.2.msi"
              onChange={(e) => setUrl(e.target.value)} />
            <span className="mt-0.5 block text-xs text-slate-400">
              Must be https. An installer fetched over plain HTTP on a café connection
              is the easiest thing in this product to tamper with, and the school would
              have no way to know, so the database refuses it.
            </span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">SHA-256 checksum</span>
            <input className={`${FIELD} font-mono text-xs`} value={sha}
              onChange={(e) => setSha(e.target.value)}
              placeholder="64 hex characters" />
            <span className="mt-0.5 block text-xs text-slate-400">
              On the machine that built it:{' '}
              <code className="rounded bg-slate-200 px-1">certutil -hashfile &lt;file&gt; SHA256</code>.
              Not optional. It is the only way a school can check the file is really
              yours.
            </span>
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">
              What changed: shown to schools
            </span>
            <input className={FIELD} value={notes} onChange={(e) => setNotes(e.target.value)}
              placeholder="Faster fee counter, fixes printing on thermal printers" />
          </label>
          <button onClick={() => pub.mutate()}
            disabled={pub.isPending || !version.trim() || !url.trim() || sha.trim().length !== 64}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {pub.isPending ? 'Publishing…' : 'Publish'}
          </button>
        </div>
      )}

      {rows.length > 0 && (
        <div className="mt-3 overflow-x-auto">
          <table className="w-full min-w-[36rem] text-sm">
            <thead>
              <tr className="border-b border-slate-200 text-left text-xs uppercase tracking-wide text-slate-500">
                <th className="py-1.5">Version</th>
                <th className="py-1.5">For</th>
                <th className="py-1.5">Published</th>
                <th className="py-1.5">Checksum</th>
                <th className="py-1.5"></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.id} className={r.is_current ? '' : 'text-slate-400'}>
                  <td className="py-1.5">
                    <span className="font-medium">{r.version}</span>
                    {r.is_current && (
                      <span className="ml-2 rounded bg-emerald-100 px-1.5 py-0.5 text-xs font-medium text-emerald-800">
                        current
                      </span>
                    )}
                    {r.notes && <div className="text-xs text-slate-500">{r.notes}</div>}
                  </td>
                  <td className="py-1.5">{r.platform}{r.channel !== 'stable' && ` · ${r.channel}`}</td>
                  <td className="py-1.5 text-xs">{fmtDateTime(r.published_at)}</td>
                  <td className="py-1.5 font-mono text-xs">{r.sha256.slice(0, 12)}…</td>
                  <td className="py-1.5 text-right">
                    {r.is_current && (
                      <button
                        onClick={() => {
                          const reason = window.prompt(
                            'Why is this release being pulled? Six months from now, '
                            + '"why is 1.4.1 not current" has no other answer.')
                          if (reason?.trim()) pull.mutate({ id: r.id, reason })
                        }}
                        className="text-xs text-slate-500 hover:underline">
                        Pull it
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function Announcements() {
  const qc = useQueryClient()
  const q = useQuery({ queryKey: ['announcements'], queryFn: () => listAnnouncements() })
  const [open, setOpen] = useState(false)
  const [audience, setAudience] = useState<Audience>('staff')
  const [severity, setSeverity] = useState<Severity>('info')
  const [title, setTitle] = useState('')
  const [message, setMessage] = useState('')
  const [ends, setEnds] = useState('')
  const [err, setErr] = useState<string | null>(null)

  const post = useMutation({
    mutationFn: () => announce({
      audience, severity, title: title.trim(), message: message.trim(),
      endsAt: new Date(ends).toISOString(),
    }),
    onSuccess: () => {
      setErr(null); setOpen(false); setTitle(''); setMessage(''); setEnds('')
      void qc.invalidateQueries({ queryKey: ['announcements'] })
    },
    onError: (e) => setErr((e as Error).message),
  })

  const end = useMutation({
    mutationFn: (id: string) => endAnnouncement(id, 'ended early from the console'),
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['announcements'] }),
    onError: (e) => setErr((e as Error).message),
  })

  const rows = q.data ?? []
  const live = rows.filter((r) => r.live_now)

  return (
    <section className="rounded-lg border border-slate-200 bg-white p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 className="text-sm font-semibold text-slate-800">
            Notices to every school
          </h2>
          <p className="mt-0.5 text-xs text-slate-500">
            A banner inside the software. {live.length} showing now.
          </p>
        </div>
        <button onClick={() => { setOpen((v) => !v); setErr(null) }}
          className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700">
          {open ? 'Cancel' : 'Post a notice'}
        </button>
      </div>

      {err && <p className="mt-3 rounded bg-red-50 px-3 py-2 text-sm text-red-700">{err}</p>}

      {open && (
        <div className="mt-3 space-y-3 rounded border border-slate-200 bg-slate-50 p-3">
          <div className="grid gap-3 sm:grid-cols-3">
            <label className="block">
              <span className="text-xs font-medium text-slate-600">Who sees it</span>
              <select className={FIELD} value={audience}
                onChange={(e) => setAudience(e.target.value as Audience)}>
                <option value="staff">School staff</option>
                <option value="owners">Owners and principals only</option>
                <option value="parents">Parents, in the portal</option>
                <option value="everyone">Everyone</option>
              </select>
            </label>
            <label className="block">
              <span className="text-xs font-medium text-slate-600">How loud</span>
              <select className={FIELD} value={severity}
                onChange={(e) => setSeverity(e.target.value as Severity)}>
                <option value="info">Information</option>
                <option value="warning">Warning</option>
                <option value="critical">Critical</option>
              </select>
            </label>
            <label className="block">
              <span className="text-xs font-medium text-slate-600">Stops showing</span>
              <input type="datetime-local" className={FIELD} value={ends}
                onChange={(e) => setEnds(e.target.value)} />
              <span className="mt-0.5 block text-xs text-slate-400">
                Required. A banner with no end date is still telling schools about last
                March, and one nobody believes takes the next one down with it.
              </span>
            </label>
          </div>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">Heading</span>
            <input className={FIELD} value={title} onChange={(e) => setTitle(e.target.value)}
              placeholder="Maintenance on Sunday morning" />
          </label>
          <label className="block">
            <span className="text-xs font-medium text-slate-600">What to tell them</span>
            <textarea rows={3} className={FIELD} value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder="The software will be unavailable on Sunday between 6 and 7am while we upgrade the server. Nothing will be lost." />
            <span className="mt-0.5 block text-xs text-slate-400">
              Written as the school will read it. Say what it means for them and whether
              anything of theirs is at risk. That is the question they will have.
            </span>
          </label>
          <button onClick={() => post.mutate()}
            disabled={post.isPending || !title.trim() || !message.trim() || !ends}
            className="rounded bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-60">
            {post.isPending ? 'Posting…' : 'Post it'}
          </button>
        </div>
      )}

      {rows.length === 0 && !q.isLoading && (
        <p className="mt-3 text-sm text-slate-500">Nothing posted yet.</p>
      )}

      <div className="mt-3 space-y-2">
        {rows.map((a) => <Row key={a.id} a={a} onEnd={() => end.mutate(a.id)} />)}
      </div>
    </section>
  )
}

function Row({ a, onEnd }: { a: Announcement; onEnd: () => void }) {
  const tone = a.severity === 'critical' ? 'border-red-300 bg-red-50'
    : a.severity === 'warning' ? 'border-amber-300 bg-amber-50'
    : 'border-slate-200'
  return (
    <div className={`rounded border px-3 py-2 ${a.live_now ? tone : 'border-slate-200 opacity-60'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="text-sm font-medium text-slate-800">
            {a.title}
            {a.live_now && (
              <span className="ml-2 rounded bg-emerald-100 px-1.5 py-0.5 text-xs font-medium text-emerald-800">
                showing now
              </span>
            )}
          </div>
          <div className="text-sm text-slate-600">{a.message}</div>
          <div className="mt-0.5 text-xs text-slate-400">
            {AUDIENCE_LABEL[a.audience]} · {a.severity} ·{' '}
            {fmtDateTime(a.starts_at)} to {fmtDateTime(a.ends_at)}
          </div>
        </div>
        {a.live_now && (
          <button onClick={onEnd} className="shrink-0 text-xs text-slate-500 hover:underline">
            Stop showing it
          </button>
        )}
      </div>
    </div>
  )
}

const AUDIENCE_LABEL: Record<string, string> = {
  staff: 'School staff',
  owners: 'Owners and principals',
  parents: 'Parents',
  everyone: 'Everyone',
}

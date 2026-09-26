import { useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  listClassesAll, createClass, setClassActive, listSections, createSection,
  listSubjects, createSubject, updateSubject, deleteSubject, copySubjectsToClasses,
  renameClass, setClassOrder, renameSection, getCurrentSession, getClassStrength,
  type ClassFull, type SubjectRow,
} from '@/lib/db'
import { LoadError, Button, buttonClass } from '@/components/ui'
import { AskDialog } from '@/components/AskDialog'
import { ObserverNotice } from '@/components/ObserverNotice'
import { useAuth } from '@/auth/AuthProvider'
import { canWrite } from '@/auth/roles'

const FIELD = 'rounded-lg border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100'

/**
 * The class ladder.
 *
 * WHAT WAS WRONG. A class could not be renamed, a section could not be renamed,
 * and the order was a number typed once when the class was made and never
 * editable again, so "Prep" added in the second week sat above Class 10 for
 * ever. Two classes could both be called "Class 5". And "Deactivate" on a class
 * with thirty children in it hid those children from every class picker in the
 * app (their register, their challans, their results) with no question asked.
 * The database now refuses that and says how many are in it; the screen shows
 * the count before anybody presses anything.
 */
export function ClassesSections() {
  const qc = useQueryClient()
  const { profile } = useAuth()
  const mayWrite = canWrite(profile?.role)
  const classes = useQuery({ queryKey: ['classesAll'], queryFn: listClassesAll })
  const session = useQuery({ queryKey: ['currentSession'], queryFn: getCurrentSession })
  const strength = useQuery({ queryKey: ['rptStrength', session.data?.id], queryFn: () => getClassStrength(session.data!.id), enabled: !!session.data?.id })
  const [name, setName] = useState('')
  const [showOff, setShowOff] = useState(false)

  const all = classes.data ?? []
  const active = all.filter((c) => c.active)
  const off = all.filter((c) => !c.active)
  const pupils = (className: string, section?: string | null) => (strength.data ?? [])
    .filter((r) => r.class_name === className && (section === undefined || (r.section_name ?? null) === section))
    .reduce((t, r) => t + r.total, 0)
  const taken = !!name.trim() && all.some((c) => c.name.trim().toLowerCase() === name.trim().toLowerCase())

  const refresh = () => { qc.invalidateQueries({ queryKey: ['classesAll'] }); qc.invalidateQueries({ queryKey: ['classes'] }) }
  const add = useMutation({
    mutationFn: () => createClass(name.trim(), (Math.max(0, ...all.map((c) => c.level_order)) || 0) + 10),
    onSuccess: () => { setName(''); refresh() },
  })
  const move = useMutation({
    mutationFn: (ids: string[]) => setClassOrder(ids),
    onSuccess: refresh,
  })
  function shift(id: string, by: -1 | 1) {
    const ids = active.map((c) => c.id)
    const i = ids.indexOf(id)
    const j = i + by
    if (i < 0 || j < 0 || j >= ids.length) return
    ;[ids[i], ids[j]] = [ids[j], ids[i]]
    move.mutate([...ids, ...off.map((c) => c.id)])
  }

  const onRoll = (strength.data ?? []).reduce((t, r) => t + r.total, 0)

  return (
    <div className="max-w-4xl space-y-4">
      <LoadError of={[classes]} what="Your classes" />
      {!mayWrite && <ObserverNotice what="the classes" />}

      {active.length > 0 && (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
          <Stat n={active.length} label={active.length === 1 ? 'class' : 'classes'} />
          <Stat n={onRoll} label={`children in ${session.data?.name ?? 'this year'}`} />
          <Stat n={off.length} label="switched off" />
        </div>
      )}
      {move.isError && <p className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(move.error as Error).message}</p>}

      <div className="space-y-3">
        {all.length === 0 && !classes.isLoading && (
          <p className="rounded-xl border border-dashed border-slate-300 bg-white px-4 py-6 text-center text-sm text-slate-500">No classes yet. Add the first one below.</p>
        )}
        {active.map((c, i) => (
          <ClassCard key={c.id} cls={c} allClasses={all} mayWrite={mayWrite} pupils={pupils}
            first={i === 0} last={i === active.length - 1} moving={move.isPending}
            onUp={() => shift(c.id, -1)} onDown={() => shift(c.id, 1)} />
        ))}
      </div>

      {mayWrite && (
        <form className="flex flex-wrap items-end gap-2 rounded-2xl border border-slate-200 bg-white p-4 shadow-card" onSubmit={(e) => { e.preventDefault(); if (name.trim() && !taken) add.mutate() }}>
          <label className="block min-w-0 flex-1">
            <span className="mb-1 block text-xs font-medium text-slate-600">Add a class</span>
            <input value={name} onChange={(e) => setName(e.target.value)} className={`w-full ${FIELD}`} placeholder="e.g. Nursery, Class 1, Class 9" />
            {taken && <span className="mt-1 block text-xs text-danger-700">There is already a class called that.</span>}
          </label>
          <Button type="submit" disabled={!name.trim() || taken || add.isPending}>{add.isPending ? 'Adding…' : 'Add class'}</Button>
          {add.isError && <span className="w-full text-sm text-danger-700">{(add.error as Error).message}</span>}
          <p className="w-full text-xs text-slate-500">It goes at the bottom of the ladder. Move it up with the arrows.</p>
        </form>
      )}

      {off.length > 0 && (
        <div>
          <button type="button" onClick={() => setShowOff(!showOff)} className={buttonClass({ variant: 'soft', size: 'sm' })}>
            {showOff ? 'Hide' : 'Show'} the {off.length} switched-off class{off.length === 1 ? '' : 'es'}
          </button>
          {showOff && (
            <div className="mt-2 space-y-3">
              {off.map((c) => (
                <ClassCard key={c.id} cls={c} allClasses={all} mayWrite={mayWrite} pupils={pupils} first last moving={false} onUp={() => {}} onDown={() => {}} />
              ))}
            </div>
          )}
        </div>
      )}
      <p className="text-xs text-slate-500">
        The order is the class ladder: Year rollover promotes each class to the one below it, and every
        list in the app follows it. Switching a class off hides it from new admissions and keeps its history.
      </p>
    </div>
  )
}

function Stat({ n, label }: { n: number; label: string }) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-white px-4 py-3 shadow-card">
      <div className="text-2xl font-semibold tabular-nums text-slate-900">{n}</div>
      <div className="text-xs text-slate-500">{label}</div>
    </div>
  )
}

function ClassCard({ cls, allClasses, mayWrite, pupils, first, last, moving, onUp, onDown }: {
  cls: ClassFull; allClasses: ClassFull[]; mayWrite: boolean
  pupils: (className: string, section?: string | null) => number
  first: boolean; last: boolean; moving: boolean; onUp: () => void; onDown: () => void
}) {
  const qc = useQueryClient()
  const sections = useQuery({ queryKey: ['sections', cls.id], queryFn: () => listSections(cls.id) })
  const [sec, setSec] = useState('')
  const [renaming, setRenaming] = useState(false)
  const [newName, setNewName] = useState(cls.name)
  const [askOff, setAskOff] = useState(false)
  const n = pupils(cls.name)

  const refresh = () => { qc.invalidateQueries({ queryKey: ['classesAll'] }); qc.invalidateQueries({ queryKey: ['classes'] }) }
  const addSec = useMutation({
    mutationFn: () => createSection(cls.id, sec.trim(), sections.data?.length ?? 0),
    onSuccess: () => { setSec(''); qc.invalidateQueries({ queryKey: ['sections', cls.id] }); qc.invalidateQueries({ queryKey: ['allSections'] }) },
  })
  const toggle = useMutation({
    mutationFn: () => setClassActive(cls.id, !cls.active),
    onSuccess: () => { setAskOff(false); refresh() },
  })
  const rename = useMutation({
    mutationFn: () => renameClass(cls.id, newName),
    onSuccess: () => { setRenaming(false); refresh() },
  })
  const nameTaken = newName.trim().toLowerCase() !== cls.name.trim().toLowerCase()
    && allClasses.some((c) => c.name.trim().toLowerCase() === newName.trim().toLowerCase())

  return (
    <div className={`rounded-2xl border border-slate-200 bg-white p-4 shadow-card ${cls.active ? '' : 'bg-slate-50'}`}>
      <div className="flex flex-wrap items-start justify-between gap-2">
        {renaming ? (
          <form className="flex min-w-0 flex-1 flex-wrap items-center gap-2" onSubmit={(e) => { e.preventDefault(); if (newName.trim() && !nameTaken) rename.mutate() }}>
            <input autoFocus value={newName} onChange={(e) => setNewName(e.target.value)} className={`min-w-0 flex-1 ${FIELD}`} aria-label="Class name" />
            <Button type="submit" size="sm" disabled={!newName.trim() || nameTaken || rename.isPending}>Save</Button>
            <Button type="button" size="sm" variant="soft" tone="neutral" onClick={() => { setRenaming(false); setNewName(cls.name); rename.reset() }}>Cancel</Button>
            {nameTaken && <span className="w-full text-xs text-danger-700">Another class is already called that.</span>}
            {rename.isError && <span className="w-full text-xs text-danger-700">{(rename.error as Error).message}</span>}
          </form>
        ) : (
          <div className="min-w-0">
            <div className="flex flex-wrap items-center gap-2">
              <span className={`text-base font-semibold ${cls.active ? 'text-slate-900' : 'text-slate-500'}`}>{cls.name}</span>
              {!cls.active && <span className="rounded-full bg-slate-200 px-2 py-0.5 text-[11px] font-medium text-slate-600">switched off</span>}
            </div>
            <div className="text-xs text-slate-500">{n} {n === 1 ? 'child' : 'children'} this year</div>
          </div>
        )}
        {mayWrite && !renaming && (
          <div className="flex flex-wrap items-center gap-1">
            {cls.active && (
              <>
                <button type="button" onClick={onUp} disabled={first || moving} aria-label={`Move ${cls.name} up`}
                  className="grid h-8 w-8 place-items-center rounded-lg text-slate-500 ring-1 ring-slate-200 hover:bg-slate-50 disabled:opacity-30">↑</button>
                <button type="button" onClick={onDown} disabled={last || moving} aria-label={`Move ${cls.name} down`}
                  className="grid h-8 w-8 place-items-center rounded-lg text-slate-500 ring-1 ring-slate-200 hover:bg-slate-50 disabled:opacity-30">↓</button>
              </>
            )}
            <Button size="sm" variant="ghost" onClick={() => setRenaming(true)}>Rename</Button>
            <Button size="sm" variant="ghost" onClick={() => { toggle.reset(); if (cls.active) setAskOff(true); else toggle.mutate() }}>
              {cls.active ? 'Switch off' : 'Switch on'}
            </Button>
          </div>
        )}
      </div>
      {toggle.isError && !askOff && <p className="mt-2 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">{(toggle.error as Error).message}</p>}

      <div className="mt-3 flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-slate-500">Sections</span>
        {sections.data?.length === 0 && <span className="text-sm text-slate-400">none: the class is one register</span>}
        {sections.data?.map((s) => (
          <SectionChip key={s.id} id={s.id} name={s.name} count={pupils(cls.name, s.name)} mayWrite={mayWrite}
            onChanged={() => { qc.invalidateQueries({ queryKey: ['sections', cls.id] }); qc.invalidateQueries({ queryKey: ['allSections'] }) }} />
        ))}
        {mayWrite && (
          <form className="ml-auto flex items-center gap-1" onSubmit={(e) => { e.preventDefault(); if (sec.trim()) addSec.mutate() }}>
            <input value={sec} onChange={(e) => setSec(e.target.value)} placeholder="New section (A, B…)" aria-label={`New section for ${cls.name}`} className={`w-36 ${FIELD} py-1`} />
            <Button type="submit" size="sm" variant="soft" tone="brand" disabled={!sec.trim() || addSec.isPending}>Add</Button>
          </form>
        )}
      </div>
      {addSec.isError && <p className="mt-1 text-xs text-danger-700">{(addSec.error as Error).message}</p>}

      <SubjectsBlock cls={cls} allClasses={allClasses} />

      {askOff && n > 0 && (
        <div className="mt-3 rounded-xl border border-due-200 bg-due-50 p-3 text-sm text-due-900" role="alert">
          <b>{n} {n === 1 ? 'child is' : 'children are'} in {cls.name} this year</b>, so it cannot be switched off: a
          switched-off class disappears from every class list, and their register, challans and results could not be
          reached. Move them to another class first, or switch it off after Year rollover has moved them on.
          <div className="mt-2"><Button size="sm" variant="soft" tone="neutral" onClick={() => setAskOff(false)}>Close</Button></div>
        </div>
      )}
      {askOff && n === 0 && (
        <AskDialog
          title={`Switch off ${cls.name}?`}
          intro={<>Nobody is in {cls.name} this year. It stops appearing for new admissions and keeps everything from earlier years.</>}
          confirmLabel="Switch it off"
          tone="danger"
          busy={toggle.isPending}
          error={toggle.error ? (toggle.error as Error).message : null}
          onCancel={() => setAskOff(false)}
          onSubmit={() => toggle.mutate()}
        />
      )}
    </div>
  )
}

function SectionChip({ id, name, count, mayWrite, onChanged }: {
  id: string; name: string; count: number; mayWrite: boolean; onChanged: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [v, setV] = useState(name)
  const save = useMutation({ mutationFn: () => renameSection(id, v), onSuccess: () => { setEditing(false); onChanged() } })
  if (editing) {
    return (
      <form className="inline-flex flex-wrap items-center gap-1" onSubmit={(e) => { e.preventDefault(); if (v.trim()) save.mutate() }}>
        <input autoFocus value={v} onChange={(e) => setV(e.target.value)} aria-label="Section name" className={`w-20 ${FIELD} py-0.5 text-xs`} />
        <button type="submit" disabled={save.isPending} className={buttonClass({ size: 'sm' })}>Save</button>
        <button type="button" onClick={() => { setEditing(false); setV(name); save.reset() }} className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Cancel</button>
        {save.isError && <span className="text-xs text-danger-700">{(save.error as Error).message}</span>}
      </form>
    )
  }
  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-0.5 text-xs font-medium text-brand-800 ring-1 ring-brand-100">
      {name}<span className="font-normal text-brand-600">· {count}</span>
      {mayWrite && <button type="button" onClick={() => setEditing(true)} className="ml-0.5 text-brand-400 hover:text-brand-700" aria-label={`Rename section ${name}`}>✎</button>}
    </span>
  )
}

/**
 * The subjects a class teaches, managed where a class is managed.
 *
 * Subject creation used to live only inside Exam Setup, so a school that had
 * not set up an exam had no subjects, and the Subject Teachers tab and the
 * subject-wise attendance register were empty with nothing to add. This is the
 * same per-class subjects table (school_id, class_id, name) surfaced where you
 * would look for it, plus a copy-into-other-classes button so a common list is
 * set once rather than re-typed twelve times.
 */
function SubjectsBlock({ cls, allClasses }: { cls: ClassFull; allClasses: ClassFull[] }) {
  const qc = useQueryClient()
  const subjects = useQuery({ queryKey: ['subjects', cls.id], queryFn: () => listSubjects(cls.id) })
  const [name, setName] = useState('')
  const [err, setErr] = useState<string | null>(null)
  const [copying, setCopying] = useState(false)

  const refresh = () => qc.invalidateQueries({ queryKey: ['subjects', cls.id] })

  const add = useMutation({
    mutationFn: () => createSubject(name.trim(), cls.id),
    onSuccess: () => { setName(''); setErr(null); refresh() },
    onError: (e) => setErr((e as Error).message),
  })

  const list = subjects.data ?? []

  return (
    <div className="mt-3 border-t border-slate-100 pt-3">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium text-slate-500">Subjects</span>
        {subjects.isLoading && <span className="text-sm text-slate-400">…</span>}
        {!subjects.isLoading && list.length === 0 && <span className="text-sm text-slate-400">none</span>}
        {list.map((s) => (
          <SubjectChip key={s.id} subject={s} onChanged={refresh} onError={setErr} />
        ))}
        <form className="ml-auto flex items-center gap-1"
          onSubmit={(e) => { e.preventDefault(); if (name.trim()) add.mutate() }}>
          <input value={name} onChange={(e) => setName(e.target.value)}
            placeholder="+ subject (Maths…)" className={`w-40 ${FIELD} py-1`} />
          <button type="submit" disabled={!name.trim() || add.isPending}
            className="rounded border border-slate-300 px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-60">Add</button>
        </form>
      </div>

      {list.length > 0 && allClasses.length > 1 && (
        <div className="mt-1.5">
          {!copying ? (
            <button onClick={() => { setErr(null); setCopying(true) }}
              className={buttonClass({ variant: 'soft', size: 'sm' })}>
              Copy these subjects to other classes
            </button>
          ) : (
            <CopySubjects cls={cls} allClasses={allClasses}
              onDone={() => { setCopying(false); refresh() }}
              onCancel={() => setCopying(false)}
              onError={setErr} />
          )}
        </div>
      )}

      {err && <p className="mt-1 text-xs text-danger-700">{err}</p>}
    </div>
  )
}

function SubjectChip({ subject, onChanged, onError }: {
  subject: SubjectRow; onChanged: () => void; onError: (m: string | null) => void
}) {
  const [editing, setEditing] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [name, setName] = useState(subject.name)

  const rename = useMutation({
    mutationFn: () => updateSubject(subject.id, name.trim()),
    onSuccess: () => { setEditing(false); onError(null); onChanged() },
    onError: (e) => onError((e as Error).message),
  })
  const remove = useMutation({
    // A refusal (marks attached) comes back as {deleted:false,message}, not a
    // throw, so it is shown as a fact rather than a red error.
    mutationFn: () => deleteSubject(subject.id),
    onSuccess: (r) => {
      setConfirming(false)
      if (!r.deleted) onError(r.message)
      else { onError(null); onChanged() }
    },
    onError: (e) => onError((e as Error).message),
  })

  if (editing) {
    return (
      <form className="inline-flex items-center gap-1"
        onSubmit={(e) => { e.preventDefault(); if (name.trim()) rename.mutate() }}>
        <input autoFocus value={name} onChange={(e) => setName(e.target.value)}
          className={`w-32 ${FIELD} py-0.5 text-xs`} />
        <button type="submit" disabled={rename.isPending}
          className={buttonClass({ size: 'sm' })}>Save</button>
        <button type="button" onClick={() => { setEditing(false); setName(subject.name) }}
          className={buttonClass({ variant: 'soft', tone: 'neutral', size: 'sm' })}>Cancel</button>
      </form>
    )
  }

  return (
    <span className="inline-flex items-center gap-1 rounded-full bg-slate-100 px-2.5 py-0.5 text-xs text-slate-700">
      {subject.name}
      {subject.is_practical && <span className="text-[10px] text-slate-400">(prac)</span>}
      {confirming ? (
        <>
          <button onClick={() => remove.mutate()} disabled={remove.isPending}
            className="text-danger-700 hover:underline">remove?</button>
          <button onClick={() => setConfirming(false)} className="text-slate-400 hover:underline">no</button>
        </>
      ) : (
        <>
          <button onClick={() => { onError(null); setEditing(true) }}
            className="text-slate-400 hover:text-brand-700" title="Rename">✎</button>
          <button onClick={() => { onError(null); setConfirming(true) }}
            className="text-slate-400 hover:text-danger-700" title="Delete">✕</button>
        </>
      )}
    </span>
  )
}

function CopySubjects({ cls, allClasses, onDone, onCancel, onError }: {
  cls: ClassFull; allClasses: ClassFull[]
  onDone: () => void; onCancel: () => void; onError: (m: string | null) => void
}) {
  const [picked, setPicked] = useState<string[]>([])
  const targets = allClasses.filter((c) => c.id !== cls.id)

  const copy = useMutation({
    mutationFn: () => copySubjectsToClasses(cls.id, picked),
    onSuccess: (r) => {
      onError(r.created === 0 && r.skipped > 0
        ? `Nothing added: those classes already had all ${r.skipped} subject(s).`
        : `Copied ${r.created} subject(s)${r.skipped ? `, skipped ${r.skipped} already present` : ''}.`)
      onDone()
    },
    onError: (e) => onError((e as Error).message),
  })

  function toggle(id: string) {
    setPicked((p) => p.includes(id) ? p.filter((x) => x !== id) : [...p, id])
  }

  return (
    <div className="rounded-lg border border-slate-200 bg-slate-50 p-2">
      <div className="text-xs text-slate-600">Copy {cls.name}'s subjects into:</div>
      <div className="mt-1.5 flex flex-wrap gap-1.5">
        {targets.map((c) => {
          const on = picked.includes(c.id)
          return (
            <label key={c.id}
              className={`cursor-pointer rounded border px-2 py-0.5 text-xs ${
                on ? 'border-brand-600 bg-brand-600 text-white' : 'border-slate-300 bg-white text-slate-700'}`}>
              <input type="checkbox" className="sr-only" checked={on} onChange={() => toggle(c.id)} />
              {c.name}
            </label>
          )
        })}
      </div>
      <div className="mt-2 flex gap-2">
        <button onClick={() => copy.mutate()} disabled={picked.length === 0 || copy.isPending}
          className="rounded bg-brand-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-brand-700 disabled:opacity-50">
          {copy.isPending ? 'Copying…' : `Copy to ${picked.length || ''} class${picked.length === 1 ? '' : 'es'}`}
        </button>
        <button onClick={onCancel} className="rounded border border-slate-300 px-2.5 py-1 text-xs text-slate-600 hover:bg-white">Cancel</button>
      </div>
    </div>
  )
}

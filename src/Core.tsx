import { useEffect, useState, type FormEvent } from 'react'
import { baseContribution, delayContribution } from '../packages/engine'
import { supabase } from './auth'

type Space = { id: string; title: string }
type Project = Space & { space_id: string; status: string }
type Task = Space & { project_id: string | null; deadline: string | null; completion: number; cancelled_at: string | null }
type Entry = { id: number; project_id: string | null; task_id: string | null; occurred_at: string; value: number; reason: string; kind: string }
type Pause = { project_id: string; began_at: string; ended_at: string | null }
type Dependency = { task_id: string; prerequisite_id: string }
type Workspace = {
  spaces: Space[]; projects: Project[]; tasks: Task[]; entries: Entry[]; pauses: Pause[]; dependencies: Dependency[]
}

async function readWorkspace(): Promise<Workspace> {
  const client = supabase!
  const [spaces, projects, tasks, pauses, dependencies] = await Promise.all([
    client.from('apex_spaces').select('id,title').order('title'),
    client.from('apex_projects').select('id,title,space_id,status').order('title'),
    client.from('apex_tasks').select('id,title,project_id,deadline,completion,cancelled_at').order('deadline', { nullsFirst: false }),
    client.from('apex_project_pauses').select('project_id,began_at,ended_at'),
    client.from('apex_task_dependencies').select('task_id,prerequisite_id'),
  ])
  for (const result of [spaces, projects, tasks, pauses, dependencies]) if (result.error) throw result.error
  const entries: Entry[] = []
  let lastId = 0
  for (;;) {
    const { data, error } = await client.from('apex_momentum')
      .select('id,project_id,task_id,occurred_at,value,reason,kind').gt('id', lastId).order('id').limit(500)
    if (error) throw error
    entries.push(...data)
    if (data.length < 500) break
    lastId = data[data.length - 1].id
  }
  return { spaces: spaces.data!, projects: projects.data!, tasks: tasks.data!, entries, pauses: pauses.data!, dependencies: dependencies.data! }
}

const ranges = ['Day', 'Week', 'Month', 'Year', 'Lifetime'] as const
type Range = typeof ranges[number]

function Momentum({ entries }: { entries: Entry[] }) {
  const [range, setRange] = useState<Range>('Week')
  const now = Date.now()
  const start = new Date(now)
  if (range === 'Day') start.setDate(start.getDate() - 1)
  if (range === 'Week') start.setDate(start.getDate() - 7)
  if (range === 'Month') start.setMonth(start.getMonth() - 1)
  if (range === 'Year') start.setFullYear(start.getFullYear() - 1)
  const ordered = [...entries].sort((a, b) => Date.parse(a.occurred_at) - Date.parse(b.occurred_at) || a.id - b.id)
  const from = range === 'Lifetime' ? Date.parse(ordered[0]?.occurred_at ?? new Date(now).toISOString()) : start.getTime()
  let value = 0
  let startingValue = 0
  const points: { time: number; value: number; reason: string; manual?: boolean }[] = []
  for (const entry of ordered) {
    value += Number(entry.value)
    const time = Date.parse(entry.occurred_at)
    if (time < from) startingValue = value
    else points.push({ time, value, reason: entry.reason, manual: entry.kind === 'manual' })
  }
  points.unshift({ time: from, value: startingValue, reason: 'Start of range' })
  points.push({ time: now, value, reason: 'Current Momentum' })
  const min = points.reduce((lowest, point) => Math.min(lowest, point.value), 0)
  const max = points.reduce((highest, point) => Math.max(highest, point.value), 0)
  const y = (score: number) => 104 - 92 * (score - min) / (max - min || 1)
  const weekDelta = ordered.filter(entry => Date.parse(entry.occurred_at) >= now - 604_800_000).reduce((sum, entry) => sum + Number(entry.value), 0)
  const x = (time: number) => 6 + 308 * (time - from) / Math.max(1, now - from)

  return <section className="glass panel momentum">
    <h2>Momentum</h2>
    <strong className="momentum-total">{value.toFixed(2)}</strong>
    <p>{(weekDelta / 7).toFixed(2)} per day over the last 7 days</p>
    <div className="segments" role="group" aria-label="Momentum range">
      {ranges.map(item => <button type="button" key={item} aria-pressed={range === item} onClick={() => setRange(item)}>{item}</button>)}
    </div>
    <svg viewBox="0 0 320 112" role="img" aria-label={`Momentum history over ${range.toLowerCase()}, current value ${value.toFixed(2)}`}>
      <line x1="6" x2="314" y1={y(0)} y2={y(0)} stroke="currentColor" opacity=".25" />
      <polyline points={points.map(point => `${x(point.time)},${y(point.value)}`).join(' ')} fill="none" stroke="var(--accent)" strokeWidth="2" vectorEffect="non-scaling-stroke" />
      {points.filter(point => point.manual).map((point, index) => <rect key={index} x={-3.5} y={-3.5}
        width={7} height={7} fill="var(--accent)" transform={`translate(${x(point.time)} ${y(point.value)}) rotate(45)`}>
        <title>{point.reason}</title>
      </rect>)}
    </svg>
    {ordered.length > 0 && <details><summary>Recent Momentum changes</summary>
      <ul>{ordered.slice(-10).reverse().map(entry => <li key={entry.id}><time dateTime={entry.occurred_at}>{new Date(entry.occurred_at).toLocaleString()}</time> · {Number(entry.value).toFixed(2)} · {entry.reason}</li>)}</ul>
    </details>}
    {ordered.length === 0 && <p>Momentum starts growing as you finish work.</p>}
  </section>
}

function TaskRow({ task, entries, tasks, prerequisites, pauses, onProgress, onCancel, onDependency, busy }: {
  task: Task
  entries: Entry[]
  tasks: Task[]
  prerequisites: string[]
  pauses: Pause[]
  onProgress: (id: string, completion: number) => void
  onCancel: (id: string) => void
  onDependency: (task: string, prerequisite: string, remove: boolean) => void
  busy: boolean
}) {
  const [progress, setProgress] = useState(task.completion)
  const [quantity, setQuantity] = useState(false)
  const [done, setDone] = useState('')
  const [total, setTotal] = useState('')
  const [confirmCancel, setConfirmCancel] = useState(false)
  useEffect(() => setProgress(task.completion), [task.completion])
  const now = Date.now()
  const deadline = task.deadline ? Date.parse(task.deadline) : now
  const pausedMs = pauses.filter(pause => pause.project_id === task.project_id).reduce((totalMs, pause) => totalMs +
    Math.max(0, Math.min(now, pause.ended_at ? Date.parse(pause.ended_at) : now) - Math.max(deadline, Date.parse(pause.began_at))), 0)
  const overdueHours = Math.max(0, (now - deadline - pausedMs) / 3_600_000)
  const quantityValid = done !== '' && Number(total) > 0 && Number(done) >= 0 && Number(done) <= Number(total)
  const percent = quantity && quantityValid ? Math.min(Number(done) === Number(total) ? 100 : 99.9999, Math.round(1_000_000 * Number(done) / Number(total)) / 10_000) : progress
  const finished = task.completion === 100 || Boolean(task.cancelled_at)
  return <li className="task-row">
    <label className="task-check">
      <input type="checkbox" checked={task.completion === 100} disabled={busy || Boolean(task.cancelled_at)} onChange={event => onProgress(task.id, event.target.checked ? 100 : 0)} />
      <span>{task.title}</span>
    </label>
    {task.deadline && <time dateTime={task.deadline}>{new Date(task.deadline).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' })}</time>}
    {task.cancelled_at && <p>Cancelled</p>}
    {overdueHours > 0 && !finished && <p>Overdue · {delayContribution(overdueHours).toFixed(2)} delay</p>}
    <details>
      <summary>Progress and scoring history</summary>
      {!task.cancelled_at && <>
        <label className="task-check"><input type="checkbox" checked={quantity} onChange={event => setQuantity(event.target.checked)} /> Enter quantities</label>
        {quantity ? <div className="core-form">
          <label>Done<input type="number" min="0" step="any" value={done} onChange={event => setDone(event.target.value)} /></label>
          <label>Total<input type="number" min="0.0001" step="any" value={total} onChange={event => setTotal(event.target.value)} /></label>
        </div> : <label className="progress-field">
          <span>Task progress · {progress}%</span>
          <input type="range" min="0" max="100" value={progress} onChange={event => setProgress(Number(event.target.value))} />
        </label>}
        {(!quantity || quantityValid) && (task.deadline || percent === 100) && <p>{percent === 100 ? 'Completion' : 'Base at deadline'} · {baseContribution(percent).toFixed(2)}</p>}
        <button type="button" className="quiet" disabled={busy || (quantity && !quantityValid) || percent === task.completion} onClick={() => onProgress(task.id, percent)}>Save progress</button>
        {!finished && (confirmCancel ? <div role="group" aria-label="Confirm task cancellation">
          <p>Cancel this task? Its scoring history will stay in Momentum.</p>
          <button type="button" disabled={busy} onClick={() => onCancel(task.id)}>Confirm cancellation</button>
          <button type="button" onClick={() => setConfirmCancel(false)}>Keep task</button>
        </div> : <button type="button" className="quiet" onClick={() => setConfirmCancel(true)}>Cancel task</button>)}
      </>}
      <h3>Prerequisites</h3>
      <ul>{prerequisites.map(id => <li key={id}>{tasks.find(item => item.id === id)?.title ?? 'Task'}
        <button type="button" disabled={busy} className="quiet" onClick={() => onDependency(task.id, id, true)}>Remove</button>
      </li>)}</ul>
      {!finished && tasks.some(item => item.id !== task.id && !prerequisites.includes(item.id)) && <form className="core-form" onSubmit={event => {
        event.preventDefault()
        const id = String(new FormData(event.currentTarget).get('prerequisite') || '')
        if (id) onDependency(task.id, id, false)
      }}>
        <label>Prerequisite<select name="prerequisite" required>
          <option value="">Choose a task</option>
          {tasks.filter(item => item.id !== task.id && !prerequisites.includes(item.id)).map(item => <option key={item.id} value={item.id}>{item.title}</option>)}
        </select></label>
        <button disabled={busy}>Add prerequisite</button>
      </form>}
      {entries.length > 0 && <ul aria-label="Scoring history">
        {entries.slice(-12).reverse().map(entry => <li key={entry.id}>{entry.value > 0 ? '+' : ''}{Number(entry.value).toFixed(4)} · {entry.reason}</li>)}
      </ul>}
    </details>
  </li>
}

export function Core({ route, owner }: { route: string; owner: string }) {
  const [data, setData] = useState<Workspace | null>(null)
  const [problem, setProblem] = useState('')
  const [busy, setBusy] = useState(false)
  const [filter, setFilter] = useState('all')
  const projectId = /^#\/projects\/([^/]+)$/.exec(route)?.[1]
  const projectsPage = route.startsWith('#/projects')
  const project = data?.projects.find(item => item.id === projectId)

  useEffect(() => {
    let mounted = true
    readWorkspace().then(
      workspace => { if (mounted) setData(workspace) },
      () => { if (mounted) setProblem('Could not load your workspace. Refresh to try again.') },
    )
    return () => { mounted = false }
  }, [owner])

  async function change(write: () => PromiseLike<{ error: unknown }>, form?: HTMLFormElement) {
    if (busy) return
    setBusy(true)
    setProblem('')
    try {
      const { error } = await write()
      if (error) throw error
      form?.reset()
      setData(await readWorkspace())
    } catch (error) {
      const message = typeof error === 'object' && error !== null && 'message' in error ? error.message : null
      setProblem(message === 'That dependency would create a cycle.' ? message : 'Could not save or refresh your workspace. Refresh before retrying.')
    } finally {
      setBusy(false)
    }
  }

  function add(event: FormEvent<HTMLFormElement>, kind: 'space' | 'project' | 'task') {
    event.preventDefault()
    const form = event.currentTarget
    const fields = new FormData(form)
    const title = String(fields.get('title') ?? '').trim()
    if (!title) return
    const client = supabase!
    if (kind === 'space') void change(() => client.from('apex_spaces').insert({ title }), form)
    if (kind === 'project') void change(() => client.from('apex_projects').insert({ title, space_id: fields.get('space') }), form)
    if (kind === 'task') {
      const date = String(fields.get('deadline') ?? '')
      void change(() => client.from('apex_tasks').insert({
        title,
        project_id: project?.id ?? (fields.get('project') || null),
        deadline: date ? new Date(date).toISOString() : null,
      }), form)
    }
  }

  if (!data) return <section className="glass panel" role="status">{problem || 'Loading workspace…'}</section>
  if (projectId && !project) return <section className="glass panel"><p>This project could not be found.</p><a href="#/projects">Back to projects</a></section>
  const tasks = data.tasks.filter(task => !project || task.project_id === project.id)
  const entries = data.entries.filter(entry => !project || entry.project_id === project.id)

  return <div className="core">
    {problem && <p role="alert">{problem}</p>}
    {projectsPage && !project && <section className="glass panel">
      <h2>Spaces</h2>
      <form className="core-form" onSubmit={event => add(event, 'space')}>
        <label>Space name<input name="title" required maxLength={100} placeholder="Academics" /></label>
        <button className="primary" disabled={busy}>Add space</button>
      </form>
      {data.spaces.length > 0 && <form className="core-form" onSubmit={event => add(event, 'project')}>
        <label>Project name<input name="title" required maxLength={100} /></label>
        <label>Space<select name="space" required>{data.spaces.map(space => <option key={space.id} value={space.id}>{space.title}</option>)}</select></label>
        <button className="primary" disabled={busy}>Add project</button>
      </form>}
      <label className="project-filter">Project status<select value={filter} onChange={event => setFilter(event.target.value)}>
        {['all', 'active', 'paused', 'inactive', 'completed', 'archived'].map(status => <option key={status} value={status}>{status[0].toUpperCase() + status.slice(1)}</option>)}
      </select></label>
      {data.spaces.map(space => <div key={space.id} className="space-group">
        <h3>{space.title}</h3>
        <ul>{data.projects.filter(item => item.space_id === space.id && (filter === 'all' || item.status === filter)).map(item => <li key={item.id}><a href={`#/projects/${item.id}`}>{item.title}</a> · {item.status}</li>)}</ul>
      </div>)}
    </section>}
    {project && <section className="glass panel"><a href="#/projects">All projects</a><h2>{project.title}</h2>
      <p>{project.status === 'paused' ? 'Paused · overdue delay is on hold' : project.status}</p>
      {['active', 'paused'].includes(project.status) && <button className="quiet" disabled={busy} onClick={() => void change(() =>
        supabase!.from('apex_projects').update({ status: project.status === 'paused' ? 'active' : 'paused' }).eq('id', project.id)
      )}>{project.status === 'paused' ? 'Resume project' : 'Pause project'}</button>}
      <form className="core-form" onSubmit={event => {
        event.preventDefault()
        const form = event.currentTarget
        const fields = new FormData(form)
        const amount = Number(fields.get('amount'))
        const reason = String(fields.get('reason') || '').trim()
        if (amount && reason) void change(() => supabase!.rpc('apex_manual_momentum', { target: project.id, amount, explanation: reason }), form)
      }}>
        <label>Momentum adjustment<input name="amount" type="number" required step="any" min="-1000000" max="1000000" /></label>
        <label>Reason<input name="reason" required maxLength={240} /></label>
        <button className="quiet" disabled={busy}>Record adjustment</button>
      </form>
    </section>}
    {(!projectsPage || project) && <>
      <Momentum entries={entries} />
      <section className="glass panel">
        <h2>Tasks</h2>
        <form className="core-form" onSubmit={event => add(event, 'task')}>
          <label>Task title<input name="title" required maxLength={200} /></label>
          {!project && data.projects.length > 0 && <label>Project<select name="project"><option value="">No project</option>{data.projects.map(item => <option key={item.id} value={item.id}>{item.title}</option>)}</select></label>}
          <label>Deadline <small>(optional)</small><input type="datetime-local" name="deadline" /></label>
          <button className="primary" disabled={busy}>Add task</button>
        </form>
        {tasks.length === 0 && <p>No tasks yet.</p>}
        <ul className="tasks">{tasks.map(task => <TaskRow key={task.id} task={task} entries={entries.filter(entry => entry.task_id === task.id)} busy={busy}
          pauses={data.pauses} tasks={data.tasks}
          prerequisites={data.dependencies.filter(item => item.task_id === task.id).map(item => item.prerequisite_id)}
          onCancel={id => void change(() => supabase!.rpc('apex_cancel_task', { target: id }))}
          onDependency={(id, prerequisite, remove) => void change(() => remove
            ? supabase!.from('apex_task_dependencies').delete().eq('task_id', id).eq('prerequisite_id', prerequisite)
            : supabase!.from('apex_task_dependencies').insert({ task_id: id, prerequisite_id: prerequisite })
          )}
          onProgress={(id, completion) => void change(() => supabase!.from('apex_tasks').update({ completion }).eq('id', id))} />)}</ul>
      </section>
    </>}
  </div>
}

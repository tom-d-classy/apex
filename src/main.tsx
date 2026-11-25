import { useEffect, useState, type FormEvent } from 'react'
import { createRoot } from 'react-dom/client'
import { Calendar, Folder, House, Library, Settings, Briefcase, Moon, Sun, Monitor } from 'lucide-react'
import type { Session } from '@supabase/supabase-js'
import { Core } from './Core'
import { auth } from './auth'
import './style.css'

const routes = [
  { name: 'Home', icon: House },
  { name: 'Calendar', icon: Calendar },
  { name: 'Projects', icon: Folder },
  { name: 'Business', icon: Briefcase },
  { name: 'Knowledge', icon: Library },
  { name: 'Settings', icon: Settings },
]
const routeHref = (name: string) => '#/' + name.toLowerCase()
const logo = import.meta.env.BASE_URL + 'apex.svg'

function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [checking, setChecking] = useState(Boolean(auth))
  const [route, setRoute] = useState(location.hash)
  const [theme, setTheme] = useState(localStorage.getItem('apex-theme') || 'device')
  const [emailOpen, setEmailOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [status, setStatus] = useState('')
  const current = routes.find(item => routeHref(item.name) === route || route.startsWith(routeHref(item.name) + '/'))?.name ?? 'Home'

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    localStorage.setItem('apex-theme', theme)
  }, [theme])

  useEffect(() => {
    const update = () => setRoute(location.hash)
    window.addEventListener('hashchange', update)
    const subscription = auth?.onAuthStateChange((_event, updated) => {
      setSession(updated)
      setChecking(false)
    }).data.subscription
    return () => {
      window.removeEventListener('hashchange', update)
      subscription?.unsubscribe()
    }
  }, [])

  async function signIn(method: 'google' | 'email', email = '') {
    if (!auth) {
      setStatus('Sign-in will be available after the APEX Supabase project is connected.')
      return
    }
    setBusy(true)
    setStatus('')
    const redirect = new URL(location.pathname, location.origin).href
    try {
      const { error } = method === 'google'
        ? await auth.signInWithOAuth({ provider: 'google', options: { redirectTo: redirect } })
        : await auth.signInWithOtp({ email, options: { emailRedirectTo: redirect, shouldCreateUser: false } })
      if (error) setStatus('Sign-in could not continue. Check your details and try again.')
      else if (method === 'email') setStatus('Check your inbox for your sign-in link.')
    } catch {
      setStatus('Could not reach sign-in. Check your connection and try again.')
    } finally {
      setBusy(false)
    }
  }

  function sendLink(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    void signIn('email', String(new FormData(event.currentTarget).get('email')).trim())
  }

  if (checking) return <main className="signin"><div className="glass skeleton" role="status" aria-label="Loading APEX" /></main>

  if (!session) return (
    <main className="signin">
      <section className="glass login" aria-labelledby="app-title">
        <img className="logo" src={logo} alt="" />
        <h1 id="app-title">APEX</h1>
        <button className="primary" disabled={busy} onClick={() => void signIn('google')}>Continue with Google</button>
        <button className="quiet" aria-expanded={emailOpen} onClick={() => setEmailOpen(!emailOpen)}>Email me a link</button>
        {emailOpen && <form onSubmit={sendLink}>
          <label htmlFor="email">Email address</label>
          <input id="email" name="email" type="email" autoComplete="email" required autoFocus />
          <button className="primary" disabled={busy}>Send sign-in link</button>
        </form>}
        {status && <p className="status" role="status">{status}</p>}
      </section>
    </main>
  )

  return (
    <div className="shell">
      <nav className="glass navigation" aria-label="Main navigation">
        <a className="brand" href="#/home" aria-label="APEX home"><img src={logo} alt="" /></a>
        {routes.map(({ name, icon: Icon }) => <a key={name} href={routeHref(name)} title={name} aria-current={current === name ? 'page' : undefined}><Icon size={20} /><span>{name}</span></a>)}
      </nav>
      <header className="glass topbar">
        <span>APEX</span>
        <button className="quiet" onClick={async () => {
          const outcome = await auth?.signOut()
          if (outcome?.error) setStatus('Could not sign out. Try again.')
        }}>Sign out</button>
      </header>
      <main className="canvas">
        <h1>{current}</h1>
        {current === 'Settings' ? <section className="glass panel" aria-labelledby="appearance">
          <h2 id="appearance">Appearance</h2>
          <div className="segments" role="group" aria-label="Theme">
            {[{ value: 'device', label: 'Device', icon: Monitor }, { value: 'mist', label: 'Mist', icon: Sun }, { value: 'dusk', label: 'Dusk', icon: Moon }].map(({ value, label, icon: Icon }) =>
              <button key={value} aria-pressed={theme === value} onClick={() => setTheme(value)}><Icon size={16} />{label}</button>
            )}
          </div>
        </section> : current === 'Home' || current === 'Projects' ? <Core key={session.user.id} route={route} owner={session.user.id} /> : <section className="glass panel empty"><h2>Nothing here yet.</h2></section>}
        {status && <p role="status">{status}</p>}
      </main>
    </div>
  )
}

createRoot(document.getElementById('root')!).render(<App />)

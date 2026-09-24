import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { AuthContext, type Profile } from '@/auth/AuthProvider'
import '@/index.css'
import { SCENES } from './scenes'

/*
 * One scene per page load: ?scene=<name>. The frame imitates the app's content
 * column (the canvas colour, max-w-7xl, the same padding) without the sidebar,
 * so a screenshot at 1184px wide is what a 1440px laptop shows beside it.
 */
const name = new URLSearchParams(location.search).get('scene') ?? 'dashboard'
const scene = SCENES[name]

function authValue(profile: Profile | null) {
  return {
    session: profile ? ({ user: { id: profile.id, email: 'demo@example.test' } } as never) : null,
    profile, loading: false,
    signIn: async () => ({ error: null }),
    signOut: async () => {},
    sendReset: async () => ({ error: null }),
    setPassword: async () => ({ error: null }),
  }
}

const root = createRoot(document.getElementById('root')!)
if (!scene) {
  root.render(<p style={{ padding: 24 }}>No scene called {name}. Try: {Object.keys(SCENES).join(', ')}</p>)
} else {
  window.__liveErrors = scene.errors ?? {}
  window.__liveData = scene.data ?? {}
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, staleTime: Infinity, gcTime: Infinity } },
  })
  for (const [key, value] of scene.seeds) qc.setQueryData(key, value)
  root.render(
    <StrictMode>
      <MemoryRouter initialEntries={[scene.route ?? '/']}>
        <AuthContext.Provider value={authValue(scene.profile)}>
          <QueryClientProvider client={qc}>
            <div className="min-h-screen bg-slate-100">
              <div className="mx-auto max-w-7xl p-4 sm:p-6">{scene.node}</div>
            </div>
          </QueryClientProvider>
        </AuthContext.Provider>
      </MemoryRouter>
    </StrictMode>,
  )
}

import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { AuthProvider } from '@/auth/AuthProvider'
import { AppShell } from '@/components/AppShell'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { Login } from '@/pages/Login'
import { Dashboard } from '@/pages/Dashboard'
import { ModulePlaceholder } from '@/pages/ModulePlaceholder'
import { NotConfigured } from '@/pages/NotConfigured'
import { NAV } from '@/navigation'
import { isConfigured } from '@/lib/config'

export default function App() {
  if (!isConfigured) {
    return <NotConfigured />
  }

  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route
            element={
              <ProtectedRoute>
                <AppShell />
              </ProtectedRoute>
            }
          >
            <Route path="/" element={<Dashboard />} />
            {NAV.filter((n) => n.path !== '/').map((n) => (
              <Route key={n.path} path={n.path} element={<ModulePlaceholder />} />
            ))}
          </Route>
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}

import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClient } from '@/lib/queryClient'
import { AuthProvider } from '@/auth/AuthProvider'
import { AppShell } from '@/components/AppShell'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { Login } from '@/pages/Login'
import { Dashboard } from '@/pages/Dashboard'
import { FeesPage } from '@/pages/fees/FeesPage'
import { AttendancePage } from '@/pages/attendance/AttendancePage'
import { AdmissionsPage } from '@/pages/admissions/AdmissionsPage'
import { StudentsPage } from '@/pages/students/StudentsPage'
import { ExamsPage } from '@/pages/exams/ExamsPage'
import { TestsPage } from '@/pages/assessments/TestsPage'
import { StaffPage } from '@/pages/staff/StaffPage'
import { CertificatesPage } from '@/pages/certificates/CertificatesPage'
import { ReportsPage } from '@/pages/reports/ReportsPage'
import { SettingsPage } from '@/pages/SettingsPage'
import { ModulePlaceholder } from '@/pages/ModulePlaceholder'
import { NotConfigured } from '@/pages/NotConfigured'
import { NAV } from '@/navigation'
import { isConfigured } from '@/lib/config'

// Modules with real screens; the rest render a placeholder for now.
const IMPLEMENTED: Record<string, JSX.Element> = {
  '/fees': <FeesPage />,
  '/attendance': <AttendancePage />,
  '/admissions': <AdmissionsPage />,
  '/students': <StudentsPage />,
  '/exams': <ExamsPage />,
  '/assessments': <TestsPage />,
  '/staff': <StaffPage />,
  '/certificates': <CertificatesPage />,
  '/reports': <ReportsPage />,
  '/settings': <SettingsPage />,
}

export default function App() {
  if (!isConfigured) {
    return <NotConfigured />
  }

  return (
    <QueryClientProvider client={queryClient}>
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
                <Route key={n.path} path={n.path} element={IMPLEMENTED[n.path] ?? <ModulePlaceholder />} />
              ))}
            </Route>
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  )
}

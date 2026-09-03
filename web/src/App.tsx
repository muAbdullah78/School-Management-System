import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryClientProvider } from '@tanstack/react-query'
import { queryClient } from '@/lib/queryClient'
import { AuthProvider } from '@/auth/AuthProvider'
import { AppShell } from '@/components/AppShell'
import { ProtectedRoute } from '@/components/ProtectedRoute'
import { RedirectIfSignedIn } from '@/components/RedirectIfSignedIn'
import { LicenceGate } from '@/components/LicenceGate'
import { SetupGate } from '@/components/SetupGate'
import { Login } from '@/pages/Login'
import { Signup } from '@/pages/Signup'
import { ForgotPassword } from '@/pages/ForgotPassword'
import { ResetPassword } from '@/pages/ResetPassword'
import { Account } from '@/pages/Account'
import { PlatformPage } from '@/pages/platform/PlatformPage'
import { CheckIn } from '@/pages/CheckIn'
import { Dashboard } from '@/pages/Dashboard'
import { FeesPage } from '@/pages/fees/FeesPage'
import { AttendancePage } from '@/pages/attendance/AttendancePage'
import { AdmissionsPage } from '@/pages/admissions/AdmissionsPage'
import { StudentsPage } from '@/pages/students/StudentsPage'
import { ExamsPage } from '@/pages/exams/ExamsPage'
import { TestsPage } from '@/pages/assessments/TestsPage'
import { StaffPage } from '@/pages/staff/StaffPage'
import { BirthdaysPage } from '@/pages/people/BirthdaysPage'
import { EnquiriesPage } from '@/pages/admissions/EnquiriesPage'
import { CertificatesPage } from '@/pages/certificates/CertificatesPage'
import { ReportsPage } from '@/pages/reports/ReportsPage'
import { SettingsPage } from '@/pages/SettingsPage'
import { AccountsPage } from '@/pages/accounts/AccountsPage'
import { TillPage } from '@/pages/till/TillPage'
import { MessagesPage } from '@/pages/messages/MessagesPage'
import { ModulePlaceholder } from '@/pages/ModulePlaceholder'
import { NotConfigured } from '@/pages/NotConfigured'
import { PortalPage } from '@/pages/portal/PortalPage'
import { PortalRoute } from '@/components/PortalRoute'
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
  '/birthdays': <BirthdaysPage />,
  '/enquiries': <EnquiriesPage />,
  '/certificates': <CertificatesPage />,
  '/reports': <ReportsPage />,
  '/settings': <SettingsPage />,
  '/accounts': <AccountsPage />,
  '/till': <TillPage />,
  '/messages': <MessagesPage />,
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
            {/* Wrapped so a signed-in user is never shown a sign-in form. See
                RedirectIfSignedIn for why /reset is deliberately not wrapped. */}
            <Route
              path="/login"
              element={
                <RedirectIfSignedIn>
                  <Login />
                </RedirectIfSignedIn>
              }
            />
            <Route
              path="/signup"
              element={
                <RedirectIfSignedIn>
                  <Signup />
                </RedirectIfSignedIn>
              }
            />
            {/* Both OUTSIDE ProtectedRoute, and they have to be. Somebody who
                has forgotten their password is signed out by definition, and the
                recovery link lands on /reset before the user has any credentials
                to offer. Putting either behind the guard would redirect them to
                the login screen they came from — with the recovery token stripped
                out of the URL on the way. */}
            <Route
              path="/forgot"
              element={
                <RedirectIfSignedIn>
                  <ForgotPassword />
                </RedirectIfSignedIn>
              }
            />
            <Route path="/reset" element={<ResetPassword />} />
            <Route path="/checkin" element={<CheckIn />} />
            {/* Signed in, but outside both the staff shell and the portal: every
                role reaches this page, and a parent has no shell to render. It
                also stays reachable when the licence has lapsed — locking a
                school out of its own password change would be indefensible. */}
            <Route
              path="/password"
              element={
                <ProtectedRoute>
                  <Account />
                </ProtectedRoute>
              }
            />
            {/* The operator console sits OUTSIDE the school app: a platform
                admin belongs to no school, so the shell and licence gate below
                have nothing to render for them. The page guards itself. */}
            <Route
              path="/platform"
              element={
                <ProtectedRoute>
                  <PlatformPage />
                </ProtectedRoute>
              }
            />
            {/* A parent account never reaches the staff shell. The database
                closes every table to it, so a parent who landed on an admin
                screen would see an empty broken page rather than data — this
                just routes them somewhere that works. Enforcement is in RLS. */}
            <Route
              element={
                <ProtectedRoute>
                  <PortalRoute>
                    <LicenceGate>
                      <SetupGate>
                        <AppShell />
                      </SetupGate>
                    </LicenceGate>
                  </PortalRoute>
                </ProtectedRoute>
              }
            >
              <Route path="/" element={<Dashboard />} />
              {NAV.filter((n) => n.path !== '/').map((n) => (
                <Route key={n.path} path={n.path} element={IMPLEMENTED[n.path] ?? <ModulePlaceholder />} />
              ))}
            </Route>
            <Route
              path="/portal"
              element={
                <ProtectedRoute>
                  <PortalPage />
                </ProtectedRoute>
              }
            />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </QueryClientProvider>
  )
}

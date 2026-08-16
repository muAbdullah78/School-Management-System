/**
 * Inline SVG icons.
 *
 * Deliberately not an icon package. This app installs as a desktop window and
 * must keep working with no network, so every asset it draws has to be in the
 * bundle. A dependency would also drag a few hundred KB in for the twenty
 * glyphs we actually use.
 *
 * All icons share one shape: 24x24 viewBox, stroke-based, inheriting
 * currentColor and sizing from the parent's font-size via `1em`. That means an
 * icon always matches the text it sits beside without per-site sizing.
 */
type IconProps = { className?: string; title?: string }

function svg(path: React.ReactNode, extra?: React.SVGProps<SVGSVGElement>) {
  return function Icon({ className, title }: IconProps) {
    return (
      <svg
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth={1.75}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden={title ? undefined : true}
        role={title ? 'img' : undefined}
        className={className ?? 'h-[1.25em] w-[1.25em]'}
        {...extra}
      >
        {title ? <title>{title}</title> : null}
        {path}
      </svg>
    )
  }
}

export const IconDashboard = svg(
  <>
    <rect x="3" y="3" width="7" height="9" rx="1.5" />
    <rect x="14" y="3" width="7" height="5" rx="1.5" />
    <rect x="14" y="12" width="7" height="9" rx="1.5" />
    <rect x="3" y="16" width="7" height="5" rx="1.5" />
  </>,
)

export const IconAdmissions = svg(
  <>
    <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
    <circle cx="9" cy="7" r="4" />
    <path d="M19 8v6M22 11h-6" />
  </>,
)

export const IconStudents = svg(
  <>
    <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
    <circle cx="9" cy="7" r="4" />
    <path d="M23 21v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75" />
  </>,
)

export const IconAttendance = svg(
  <>
    <rect x="3" y="4" width="18" height="17" rx="2" />
    <path d="M16 2v4M8 2v4M3 10h18" />
    <path d="m9 15 2 2 4-4" />
  </>,
)

export const IconTests = svg(
  <>
    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
    <path d="M14 2v6h6M9 13h6M9 17h4" />
  </>,
)

export const IconExams = svg(
  <>
    <path d="M22 10 12 5 2 10l10 5 10-5Z" />
    <path d="M6 12v5c0 1.5 2.7 3 6 3s6-1.5 6-3v-5" />
  </>,
)

export const IconFees = svg(
  <>
    <rect x="2" y="5" width="20" height="14" rx="2" />
    <circle cx="12" cy="12" r="3" />
    <path d="M6 9v6M18 9v6" />
  </>,
)

export const IconStaff = svg(
  <>
    <rect x="2" y="7" width="20" height="14" rx="2" />
    <path d="M8 7V5a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M2 13h20" />
  </>,
)

export const IconCertificates = svg(
  <>
    <circle cx="12" cy="9" r="6" />
    <path d="m8.5 14-1.5 7 5-3 5 3-1.5-7" />
  </>,
)

export const IconReports = svg(
  <>
    <path d="M3 3v18h18" />
    <path d="m7 15 3-4 3 2 5-7" />
  </>,
)

export const IconSettings = svg(
  <>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1Z" />
  </>,
)

export const IconMyClass = svg(
  <>
    <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
    <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2Z" />
  </>,
)

export const IconPlatform = svg(
  <>
    <rect x="3" y="4" width="18" height="6" rx="1.5" />
    <rect x="3" y="14" width="18" height="6" rx="1.5" />
    <path d="M7 7h.01M7 17h.01" />
  </>,
)

/** Money handed over. */
export const IconWallet = svg(
  <>
    <path d="M20 12V8H6a2 2 0 0 1 0-4h12v4" />
    <path d="M4 6v12a2 2 0 0 0 2 2h14v-4" />
    <path d="M18 12a2 2 0 0 0 0 4h4v-4Z" />
  </>,
)

/** A family / the payer. */
export const IconFamily = svg(
  <>
    <circle cx="7" cy="8" r="3" />
    <circle cx="17" cy="8" r="3" />
    <path d="M2 21v-1a4 4 0 0 1 4-4h2a4 4 0 0 1 4 4v1M14 21v-1a4 4 0 0 1 4-4h1a3 3 0 0 1 3 3v2" />
  </>,
)

export const IconSearch = svg(
  <>
    <circle cx="11" cy="11" r="7" />
    <path d="m20 20-3.5-3.5" />
  </>,
)

export const IconCheck = svg(<path d="m5 13 4 4L19 7" />)
export const IconAlert = svg(
  <>
    <path d="M12 9v4M12 17h.01" />
    <path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
  </>,
)
export const IconPrint = svg(
  <>
    <path d="M6 9V2h12v7M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2" />
    <rect x="6" y="14" width="12" height="8" rx="1" />
  </>,
)
export const IconWhatsApp = svg(
  <path d="M21 11.5a8.4 8.4 0 0 1-12.6 7.3L3 20.5l1.8-5.2A8.5 8.5 0 1 1 21 11.5Z" />,
)
export const IconChevron = svg(<path d="m9 18 6-6-6-6" />)
export const IconLogout = svg(
  <>
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <path d="m16 17 5-5-5-5M21 12H9" />
  </>,
)

/** Nav path -> icon, so the shell stays declarative. */
export const NAV_ICONS: Record<string, (p: IconProps) => JSX.Element> = {
  '/': IconDashboard,
  '/admissions': IconAdmissions,
  '/students': IconStudents,
  '/attendance': IconAttendance,
  '/assessments': IconTests,
  '/exams': IconExams,
  '/fees': IconFees,
  '/staff': IconStaff,
  '/certificates': IconCertificates,
  '/reports': IconReports,
  '/settings': IconSettings,
  '/my-class': IconMyClass,
  '/platform': IconPlatform,
  '/accounts': IconWallet,
  '/till': IconWallet,
  '/messages': IconWhatsApp,
}

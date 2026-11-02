import { Link } from 'react-router-dom'

/**
 * A screen the Android app does not carry: the operator console, which bills
 * schools and so has no place in an app that may not take payments outside
 * Google Play, and signing up a new school, which the app leaves to the
 * website. The app is for signing in to a school that already exists.
 */
export function NotInTheApp({ what }: { what: string }) {
  return (
    <div className="flex min-h-full items-center justify-center bg-slate-100 p-4">
      <div className="w-full max-w-md rounded-lg bg-white p-6 text-center shadow">
        <h1 className="text-lg font-semibold text-slate-800">{what} is not part of the app</h1>
        <p className="mt-2 text-sm text-slate-600">
          The app is for signing in to your school. This part opens in a web browser on a computer.
        </p>
        <Link to="/" className="mt-5 inline-block text-sm font-medium text-brand-700 hover:underline">
          Back to the app
        </Link>
      </div>
    </div>
  )
}

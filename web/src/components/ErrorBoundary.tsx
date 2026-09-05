import { Component, type ErrorInfo, type ReactNode } from 'react'
import { useLocation } from 'react-router-dom'

/**
 * The thing that turns "the app is dead" into "this screen broke, here is why".
 *
 * WHY THIS EXISTS
 *
 * There was no error boundary anywhere in this application. In React 18 an
 * uncaught error during render unmounts the ENTIRE tree, so one bad line on one
 * screen replaced the whole app with a blank white page: no message, no
 * sidebar, no way back, and nothing written down. A school hitting it can only
 * say "the app broke", which is exactly what happened with Accounts.
 *
 * That is worse than the bug it is reporting. A clerk halfway through entering a
 * fee loses the screen and has no idea whether the money was recorded. So every
 * screen gets a boundary of its own, and the shell keeps rendering around it:
 * the sidebar stays, the other modules still work, and the person can carry on
 * with the rest of their morning while one screen is broken.
 *
 * WHY IT SHOWS THE ERROR TEXT
 *
 * Normally you hide a stack trace from users. Here the user is a school office
 * three time zones away from anybody who can read a log, and there is no error
 * reporting service in this project. The message on screen IS the bug report:
 * it is written so it can be read down a phone or photographed and sent on
 * WhatsApp, which is how support actually reaches us.
 *
 * It deliberately does NOT show the component stack, which is noise to a
 * non-programmer and can name internal fields. The message and the screen are
 * what identify the fault.
 */
interface Props {
  children: ReactNode
  /** Which screen this is wrapping, for the message and the console line. */
  where?: string
  /** Changing this resets the boundary. Route path, so navigating away from a
   *  broken screen and back gives it a fresh attempt rather than staying dead. */
  resetKey?: string
}

interface State { error: Error | null }

export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidUpdate(prev: Props) {
    // A boundary that has caught stays caught until something changes. Without
    // this, one broken screen poisons every later visit to it in the same
    // session, including after the data that caused it has been fixed.
    if (this.state.error && prev.resetKey !== this.props.resetKey) {
      this.setState({ error: null })
    }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    // Console, not a service: there is no error reporting in this project and
    // adding one would send a school's data somewhere it has not agreed to.
    // This is here so that a developer with the browser console open, or a
    // school reading it out to us, has the stack.
    console.error(`[${this.props.where ?? 'app'}] render failed`, error, info.componentStack)
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="mx-auto max-w-xl px-4 py-10">
        <div className="rounded-xl border border-danger-200 bg-danger-50 p-5">
          <h2 className="text-base font-semibold text-danger-900">
            This screen could not open
          </h2>
          <p className="mt-2 text-sm text-danger-800">
            Nothing has been lost and nothing has been changed. The rest of the
            app still works: use the menu on the left to carry on.
          </p>

          <div className="mt-4 rounded-lg border border-danger-200 bg-white p-3">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
              What went wrong
            </p>
            <p className="mt-1 break-words font-mono text-xs text-slate-700">
              {this.props.where ? `${this.props.where}: ` : ''}{error.message || String(error)}
            </p>
          </div>

          <p className="mt-3 text-sm text-danger-800">
            Please send us that line, or a photograph of this screen. It says
            exactly what broke and it is the fastest way for us to fix it.
          </p>

          <div className="mt-4 flex gap-2">
            <button
              onClick={() => this.setState({ error: null })}
              className="rounded-lg bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Try this screen again
            </button>
            <button
              onClick={() => { window.location.href = '/' }}
              className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Go to the dashboard
            </button>
          </div>
        </div>
      </div>
    )
  }
}

/**
 * A boundary around one routed screen, keyed on the route.
 *
 * Per screen rather than one around the whole app, deliberately. A single
 * boundary at the top would catch the error and then replace the sidebar too,
 * so a broken Accounts page would still look like a broken application. Wrapped
 * here, the shell survives, every other module still opens, and the failure is
 * scoped to the one screen that actually failed.
 */
export function RouteBoundary({ children }: { children: ReactNode }) {
  const { pathname } = useLocation()
  return (
    <ErrorBoundary where={pathname} resetKey={pathname}>
      {children}
    </ErrorBoundary>
  )
}

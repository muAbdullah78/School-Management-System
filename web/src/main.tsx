import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './index.css'
import { installNativeBridges, isNativeApp } from './native/native'

// Inside the Android app: native printing, saving files and the back button.
void installNativeBridges()

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)

// Register the service worker for offline support + installability. Production
// only, so it never interferes with the Vite dev server / HMR.
// Not inside the Android app, whose files are already on the phone.
if (import.meta.env.PROD && 'serviceWorker' in navigator && !isNativeApp()) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {
      /* offline support is a progressive enhancement; ignore failures */
    })
  })
}

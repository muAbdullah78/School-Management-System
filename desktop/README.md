# School Manager — Windows desktop shell

A thin [Tauri](https://tauri.app) wrapper that turns the School Manager web app
into a Windows desktop program. It is **not** a separate app — it just opens the
school's own hosted web app (the Cloudflare Pages / Vercel URL) in a native
window, so the admin PC gets a real "program" instead of a browser tab.

On first launch it asks for the school's app address; it remembers it after
that. (Click **Change address** on the connect screen to switch it.)

## Build the installer

The `.msi` is produced by GitHub Actions, not committed. Two ways to get one:

- **From GitHub:** open the repo's **Actions → Desktop (Windows installer) → Run
  workflow** (or push a `v*` tag). Download the `school-manager-windows-msi`
  artifact when it finishes.
- **Locally on Windows** (needs [Rust](https://rustup.rs) + Node 20):
  ```powershell
  cd desktop
  npm install
  npx tauri icon app-icon.svg   # generates icons/ once
  npx tauri build --bundles msi
  # → src-tauri/target/release/bundle/msi/*.msi
  ```

## Code signing (your step)

The build above is **unsigned**, so Windows SmartScreen shows a warning on first
run. To ship a signed installer you need a **Windows code-signing certificate**
(an EV or OV cert from a CA). With the cert's details set as repo secrets, Tauri
signs during the build — see the Tauri "Windows Code Signing" guide. This is the
one part only you can do (it needs your certificate); the wrapper and the build
workflow are ready for it.

## Notes

- The desktop shell and the teacher web app are the **same** application and the
  **same** Supabase database — the wrapper adds no data path of its own.
- Changing the web app requires no new installer; the desktop shell always loads
  the latest hosted version.

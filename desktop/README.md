# School Manager: the Windows desktop shell

A thin [Tauri](https://tauri.app) wrapper that turns the School Manager web app
into a Windows desktop program. It is **not** a separate app: it opens the
hosted web app in a native window, so the office PC gets a real "program"
instead of a browser tab, on the same data as everybody else.

## The connect screen

On first launch it shows one field, already filled in with
`https://app.theschoolmanager.site`, and the clerk presses **Open**. It is
remembered after that. There is one hosted deployment for every school, and
which school you are is decided by who signs in, so there is a right answer
and the office PC is given it rather than asked for it.

Change the field only for a school running the software at its own address.

**This screen used to be a dead end, and the fix is worth knowing about before
anybody edits it.** It navigated with `location.replace`, which leaves no
history entry, and this window has no address bar, no menu and no reload
button. So a clerk who mistyped one character got the webview's error page with
no way to type a different address, and the bad address stayed saved, so
relaunching went straight back to the same error page. The only escape was
uninstalling the program.

Three things now prevent that, and the third is the one that closes it:

1. The address is pre-filled, so there is nothing to mistype.
2. It is checked with a `no-cors` fetch before the window commits to it. That
   cannot read the response, but it separates a host that answered from a host
   that does not exist, which is exactly the typo case.
3. **The saved address is checked again on every launch.** However a bad
   address got saved, the next launch returns to the connect screen with the
   reason instead of to an error page it cannot leave.

Pressing **Open** a second time on a refused address goes anyway, so a network
oddity cannot lock anybody out either; rule 3 is what makes that safe.
`#reset` still clears the saved address.

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
signs during the build. See the Tauri "Windows Code Signing" guide. This is the
one part only you can do (it needs your certificate); the wrapper and the build
workflow are ready for it.

## Notes

- The desktop shell and the teacher web app are the **same** application and the
  **same** Supabase database, and the wrapper adds no data path of its own.
- Changing the web app requires no new installer; the desktop shell always loads
  the latest hosted version.

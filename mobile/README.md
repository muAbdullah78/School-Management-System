# The Android app

The Android app is the web app in `web/`, packaged with
[Capacitor](https://capacitorjs.com). The screens ship inside the app, so it
opens with no internet, and it talks to the same database as the website and
the Windows program. Every fix to `web/` reaches the app at its next release.

| | |
|---|---|
| Name on the phone | The School Manager |
| Package name | `site.theschoolmanager.app` (permanent once uploaded to Google Play) |
| Android versions | 7.0 and later (API 24), built for API 36 |
| Native pieces | printing, saving and sharing files, the back button, network status |

## What is different inside the app

- **Printing.** `window.print()` does nothing in an Android WebView. The app
  replaces it with Android's own printing (`SchoolPrintPlugin.java`), so every
  Print button opens the print screen: a printer, or "Save as PDF" to send a
  receipt on WhatsApp.
- **Downloads** (CSV exports, backups) go to the share sheet: WhatsApp, Drive,
  email or the Files app.
- **Back button.** Closes an open dialog first, then goes back a page, and on
  the first page puts the app in the background. Unsent work stays put.
- **Online and offline** come from Android itself (`MainActivity.java`), so the
  offline bar and the outbox react the moment the signal goes or comes back.
- **No backups to Google Drive and no copying to a new phone.** The app keeps
  its own blocks of receipt numbers; a copy on a second phone would print the
  same numbers. A new phone simply signs in.
- **Google Play's payment rules.** An app on Google Play may not sell a
  subscription or point anyone to pay outside Google Play. So the app shows the
  plan and its status and says it is managed by the school's owner, with no
  prices, bank details, "I have paid", discount codes, plan choices or invoices.
  Signing up a new school and the operator console are not in the app. The
  website and the Windows program are unchanged.
- **Links that leave the phone** (the parents' link, the password reset email,
  the staff check-in poster) use `https://app.theschoolmanager.site`, set by
  `VITE_APP_URL` if it ever moves.

## Building on a computer

Needs Node 22, Java 21 and Android Studio.

```bash
cd web && npm ci && npm run build      # with web/.env set, see web/.env.example
cd ../mobile && npm ci && npx cap sync android
npx cap open android                   # then Run in Android Studio
```

Run `npx cap sync android` again after every web build. Icons and the launch
screen are made from `site-src/icon.svg` by `node scripts/build-icons.mjs --android`.

The Capacitor packages are pinned to the same versions in `web/package.json`
and `mobile/package.json`; `node check-versions.mjs` checks that, and that the
package name has not changed.

## Releasing

Every pull request builds a debug APK in CI (the "Android app" workflow), kept
for a week to install and try. A release is a signed bundle (`.aab`).

**Once, before the first release:**

1. Make the upload key and keep it somewhere safe, with its passwords. Losing
   it means asking Google Play support to reset it.
   ```bash
   keytool -genkeypair -v -keystore upload.jks -alias upload \
     -keyalg RSA -keysize 4096 -validity 10000
   ```
2. In GitHub, Settings, Secrets and variables, Actions, add these **secrets**:
   - `ANDROID_KEYSTORE_BASE64`: the output of `base64 -w0 upload.jks`
   - `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`upload`), `ANDROID_KEY_PASSWORD`
3. And these **variables**, the same values the website is built with:
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`.
4. In Google Play Console, create the app, keep Play App Signing switched on,
   and upload the first bundle by hand to the internal testing track.

**Each release:**

1. Set `"version"` in `mobile/package.json` (for example `1.0.1`).
2. Tag and push: `git tag android-v1.0.1 && git push origin android-v1.0.1`.
3. Download the `.aab` from the workflow run and upload it in Play Console.

The version code Google Play needs is worked out from the version: `1.2.3` is
`10203`, so it always grows.

## Checklist on a real phone

Run this on the internal testing build before each release.

1. Install it. Sign in as the owner, then a teacher, then a parent.
2. Switch on airplane mode. The offline bar appears within a few seconds.
3. Offline: mark a register, enter marks, take a fee and print its receipt
   (Save as PDF, then share it to WhatsApp), record an expense, admit a pupil.
4. Export a CSV from Reports. The share sheet opens and the file saves to Drive or Files.
5. The back button closes a dialog, goes back a page, and from the dashboard leaves the app.
6. Switch airplane mode off. The work goes in; check it on the website.
7. Settings, Subscription: plan and status, no prices or bank details.
8. Users, the parents' link: it reads `https://app.theschoolmanager.site/parents`.
9. Forgot password: the email's link opens the reset page on the website.

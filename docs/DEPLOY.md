# Putting the app online

Two separate things get published, and they are independent:

| What | Folder | Who it is for |
|---|---|---|
| **The app** | `web/` | Schools, teachers, parents |
| **The marketing site** | `site/` | People deciding whether to buy |

Both are static, so both are free to host. Do the app first — the marketing
site is useless until there is something to sign up for.

---

## Why Cloudflare Pages

I recommended it before checking whether this app could even be hosted
statically. It can, but two things were missing and are now fixed (`_redirects`
and `_headers` in `web/public/`). The reasoning, stated properly:

**Vercel's free plan forbids commercial use.** Their Hobby tier is for
non-commercial projects. You are charging schools for this. Using Hobby would
put you in breach from your first paying customer, and the fix at that point is
a paid plan under pressure. Cloudflare Pages' free tier has no such restriction.

**Bandwidth is unmetered.** Netlify's free tier caps at 100 GB/month. That is
plenty at first, but a bandwidth ceiling on the thing schools depend on to
collect fees is a bad shape of risk — it fails when you are succeeding.

**It is close to Pakistan.** Cloudflare has points of presence in Karachi,
Lahore and Islamabad, so the app files load from inside the country.

**No tooling to install.** It builds from the GitHub repo. You have no terminal
set up, and this needs none.

### The honest counterpoints

**Cloudflare is not the slow part.** Your Supabase project is in
`ap-northeast-1` (Tokyo), roughly 150–200 ms from Pakistan, and every screen in
this app is database-driven. The CDN serves the files fast, then each query
still crosses to Tokyo and back. **Singapore would have been the better
region** — it usually measures 60–100 ms from Pakistan.

Moving region means creating a new project and re-running the setup, which is
about an hour. It is worth doing before you have a real school on it, and it is
not worth doing after. My suggestion: finish testing on Tokyo, and if the app
feels sluggish on a Pakistani connection, move to Singapore before the first
paying customer — not later.

**Build minutes are capped at 500/month** on the free plan. A push triggers a
build; at a few pushes a day you will not come close.

**It is another account to hold.** If you would rather not add one, Netlify is
an equally valid choice with the same settings — only the bandwidth cap differs.

---

## Deploying the app

1. **dash.cloudflare.com** → sign up → **Workers & Pages** → **Create** →
   **Pages** → **Connect to Git** → authorise GitHub → pick
   `School-Management-System`.

2. Build settings — these matter, and three of them are not the defaults:

   | Setting | Value |
   |---|---|
   | Framework preset | **None** |
   | Build command | `npm run build` |
   | Build output directory | `dist` |
   | **Root directory** | **`web`** |

   The root directory is the one people miss. The repo has `web/`, `site/`,
   `supabase/` and `desktop/` side by side; without it Cloudflare builds at the
   top level, finds no `package.json`, and fails.

3. **Environment variables** → add all three, for **Production**:

   ```
   VITE_SUPABASE_URL        https://YOUR-PROJECT.supabase.co
   VITE_SUPABASE_ANON_KEY   eyJhbGciOi... (the long anon key)
   VITE_SCHOOL_NAME         School
   ```

   > **These are read at build time, not when someone opens the page.** Vite
   > bakes them into the JavaScript. If you add or change one, you must
   > **Retry deployment** — saving the variable alone changes nothing.
   >
   > The anon key is *meant* to be public; Row Level Security is what protects
   > the data. **Never** put the `service_role` key here — it bypasses every
   > rule in the database.

4. **Save and Deploy.** You get a URL like
   `school-management-system.pages.dev`.

### Check it worked

- Open the URL. You should see a **sign-in page**, not "App not configured yet".
  If you see that message, the environment variables are missing or the deploy
  ran before you added them — add them and **Retry deployment**.
- Open `<your-url>/signup` **directly**, not by clicking. It must load the
  signup form, not a 404. That is `web/public/_redirects` doing its job: this
  app uses real URLs like `/fees` and `/portal`, and without that rule a
  bookmark or a page refresh would 404.
- Open it on a phone. The parent portal is phone-first and that is where it
  will actually be used.

---

## Deploying the marketing site

A **second** Pages project on the same repo — do not try to serve both from one.

| Setting | Value |
|---|---|
| Build command | *(leave empty)* |
| Build output directory | `site` |
| Root directory | *(leave empty)* |

No build step: it is plain HTML and CSS. Before pointing a real domain at it,
work through `site/README.md` — the placeholder domain, contact details and
trial links all still need replacing, and the page says so in visible text so
it cannot ship by accident.

---

## When you buy the domain

Suggested layout, and the reason for it:

| Address | Points at |
|---|---|
| `yourdomain.pk` | the marketing site |
| `app.yourdomain.pk` | the app |

Keeping them on separate hostnames means a marketing experiment can never take
the app down, and the app's cookies are never exposed to the marketing pages.

In Cloudflare: each Pages project → **Custom domains** → **Set up a domain**.
If the domain is registered elsewhere, Cloudflare will tell you which
nameservers to point at it.

**After the app moves to its own domain**, update Supabase → **Authentication →
URL Configuration**: set the Site URL to `https://app.yourdomain.pk` and add it
to Redirect URLs. Password resets and email confirmations use those values, so
they keep pointing at the old address until you do.

# Putting the app online

Two separate things get published, and they are independent:

| What | Folder | Who it is for |
|---|---|---|
| **The app** | `web/` | Schools, teachers, parents |
| **The marketing site** | `site/` | People deciding whether to buy |

Both are static, so both are free to host. Do the app first — the marketing
site is useless until there is something to sign up for.

---

## Why Cloudflare

I recommended it before checking whether this app could even be hosted
statically. It can, but three things were missing and are now fixed:
`_redirects` and `_headers` in `web/public/`, and `web/wrangler.jsonc` for the
Workers flow. The reasoning, stated properly:

**Vercel's free plan forbids commercial use.** Their Hobby tier is for
non-commercial projects. You are charging schools for this. Using Hobby would
put you in breach from your first paying customer, and the fix at that point is
a paid plan under pressure. Cloudflare's free tier has no such restriction.

**Bandwidth is unmetered.** Netlify's free tier caps at 100 GB/month. That is
plenty at first, but a bandwidth ceiling on the thing schools depend on to
collect fees is a bad shape of risk — it fails when you are succeeding.

**It is close to Pakistan.** Cloudflare has points of presence in Karachi,
Lahore and Islamabad, so the app files load from inside the country.

**No tooling to install.** It builds from the GitHub repo. You have no terminal
set up, and this needs none.

### The honest counterpoints

**Cloudflare is not the slow part — the database region is.** Every screen in
this app is database-driven, so the CDN serving files quickly matters less than
where the queries land.

Pick the region by distance from Pakistan:

| Region | Rough round trip from Karachi |
|---|---|
| **`ap-south-1` Mumbai** | **20–40 ms — best available** |
| `ap-southeast-1` Singapore | 60–100 ms |
| `ap-northeast-1` Tokyo | 150–200 ms |

**Mumbai is the right choice.** It is roughly 900 km away, closer than any other
Supabase region. Earlier revisions of this document said Singapore; that was
worse advice, and Mumbai supersedes it.

Region cannot be changed after a project is created — moving means a new project
and re-running this setup, about an hour. Get it right before a real school is
on it.

**Build minutes are capped at 500/month** on the free plan. A push triggers a
build; at a few pushes a day you will not come close.

**It is another account to hold.** If you would rather not add one, Netlify is
an equally valid choice with the same settings — only the bandwidth cap differs.

---

## Deploying the app

> **Cloudflare merged Pages into Workers.** "Workers & Pages → Create" now walks
> you into creating a **Worker**, with a deploy command of `npx wrangler deploy`,
> even for a static site. If the panel says **"Create a Worker"** and shows a
> *Deploy command* and a *Path* field — rather than *Build output directory* and
> *Root directory* — that is the Workers flow.
>
> **That flow is fine.** `web/wrangler.jsonc` in this repo configures it. Follow
> the Workers steps below. The older Pages steps are kept after them for accounts
> that still offer it.

### Workers flow (what most accounts now show)

**dash.cloudflare.com** → **Workers & Pages** → **Create** → **Import a
repository** → authorise GitHub → pick `School-Management-System`. Then:

| Field | Value |
|---|---|
| Build command | `npm run build` |
| Deploy command | `npx wrangler deploy` |
| **Path** | **`/web`** |
| Non-production branch deploy command | `npx wrangler versions upload` (or clear it) |

Two of those are easy to get wrong:

- **Path must be `/web`.** It is the folder the commands run in. The repo holds
  `web/`, `site/`, `supabase/` and `desktop/` side by side, and both
  `package.json` and `wrangler.jsonc` live in `web/`. Left at `/`, the build
  finds no `package.json` and fails.
- **Build command is `npm run build`, not `npm run dev`.** `dev` starts a
  development server that never exits, so the build would hang until Cloudflare
  times it out.

Then **environment variables** — add all three, for **Production**:

```
VITE_SUPABASE_URL        https://YOUR-PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY   eyJhbGciOi... (the long anon key)
VITE_SCHOOL_NAME         School
```

> **These are read at build time, not when someone opens the page.** Vite bakes
> them into the JavaScript. Adding or changing one means you must **redeploy** —
> saving the variable alone changes nothing.
>
> The anon key is *meant* to be public; Row Level Security protects the data.
> **Never** put the `service_role` key here — it bypasses every rule.

An **API token** field may appear; letting Cloudflare create one automatically
is correct.

Then **Deploy**.

### Pages flow (older accounts)

If your dashboard still offers **Pages → Connect to Git**, it works too and
needs no wrangler config:

| Setting | Value |
|---|---|
| Framework preset | **None** |
| Build command | `npm run build` |
| Build output directory | `dist` |
| **Root directory** | **`web`** |

Same three environment variables, same build-time caveat.

### Check it worked

- Open the URL. You should see a **sign-in page**, not "App not configured yet".
  That message means the environment variables were missing when the build ran —
  add them and redeploy.
- Open `<your-url>/signup` **directly**, not by clicking. It must load the form,
  not a 404. On Workers that is `not_found_handling` in `wrangler.jsonc`; on
  Pages it is `public/_redirects`. Both are in the repo.
- Open it on a phone. The parent portal is phone-first and that is where it will
  actually be used.

---

## Deploying the marketing site

A **second, separate** project on the same repo — do not try to serve both from
one.

There is no `package.json` in `site/`, so there is nothing to build and no
wrangler config needed. If your dashboard offers **Pages → Connect to Git**, use
it with an empty build command and `site` as the output directory. If it only
offers Workers, the simplest route is **Workers → Create → Upload assets** and
drag the three files from `site/` in — no repository connection, and re-uploading
takes a minute whenever the page changes. Before pointing a real domain at it,
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

In Cloudflare: each project → **Settings → Domains & Routes** (Workers) or
**Custom domains** (Pages) → add the domain.
If the domain is registered elsewhere, Cloudflare will tell you which
nameservers to point at it.

**After the app moves to its own domain**, update Supabase → **Authentication →
URL Configuration**: set the Site URL to `https://app.yourdomain.pk` and add it
to Redirect URLs. Password resets and email confirmations use those values, so
they keep pointing at the old address until you do.

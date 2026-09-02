# Marketing site

Plain HTML and CSS. No build step, no framework, no external requests. The
whole page is `index.html` plus `styles.css`, so it renders fast on a slow
connection and there is nothing to break at deploy time.

## Before it goes live: YOU DO THIS

1. **Register the domain**, then replace every `schoolmanager.pk` in
   `index.html` (`<link rel="canonical">`, the Open Graph tags, the JSON-LD
   `url`), `robots.txt` and `sitemap.xml`.
2. **Add real contact details** in the footer: phone, WhatsApp, email.
   The placeholder text says so out loud so it cannot ship by accident.
3. **Point the trial buttons** at the signup page of the deployed app
   (`https://app.<your-domain>/signup`). They currently jump to the contact
   section.

## Deploying

Any static host. Cloudflare Pages is free and fast from Pakistan:
point it at this folder, no build command, output directory `site`.

## On the claims

Every feature named on this page is one the software actually does today.
Nothing here describes something planned. If a feature is removed, remove it
here too. A marketing page that overstates the product is the fastest way to
lose the first ten schools, and they are the ten that matter most.

Two things are stated as *not* done, deliberately: the Urdu interface, and
fee collection needing a connection. Saying so costs a few visitors and saves
every one of them from finding out on a Monday morning.

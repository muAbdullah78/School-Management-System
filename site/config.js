/* ===========================================================================
 * Where the website points, and where it reads live data from.
 *
 * The marketing site is plain static HTML with no build step, so it cannot read
 * the app's .env. This one file is what you edit after deploying — and it is the
 * ONLY thing to edit, which is the point: before this, every "Start free trial"
 * button on the site was `href="#pricing"`, scrolling the visitor down the page
 * they were already on.
 *
 * WHAT GOES IN HERE IS PUBLIC. The anon key belongs in a browser bundle by
 * design — Row Level Security is what protects the data, and 0082 gives `anon`
 * SELECT on exactly two tables: the active price list, and the current release.
 * Never put the service_role key here, or anywhere a browser can see.
 *
 * If APP_URL is left empty every link that needs it says so on the page rather
 * than going nowhere. A dead button is worse than an honest one.
 * =========================================================================== */
window.SITE_CONFIG = {
  /* The deployed app, WITHOUT a trailing slash. e.g. https://app.schoolmanager.pk
     Cloudflare gives you something like
     https://school-management-system.<account>.workers.dev until you point a
     domain at it. */
  APP_URL: '',

  /* Supabase project URL and anon key — the same two values as the app's
     VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY. Used for two reads only:
     prices, and the current installer. Leave blank and the page falls back to
     the prices written into the HTML, which a CI check keeps in step with the
     database. */
  SUPABASE_URL: '',
  SUPABASE_ANON_KEY: '',

  /* Shown in the footer and on the contact card. */
  CONTACT_PHONE: '',
  CONTACT_WHATSAPP: '',
  CONTACT_EMAIL: '',

  /* Set to false to take the trial buttons down — during a migration, or when
     you are at capacity and do not want twenty new schools in one week. The
     page then invites them to get in touch instead of failing at signup. */
  SIGNUP_OPEN: true,
}

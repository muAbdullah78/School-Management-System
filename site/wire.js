/* ===========================================================================
 * Joining the website to the software.
 *
 * Before this file, site/index.html linked only to its own anchors: every
 * "Start free trial" button scrolled the visitor down the page they were already
 * on, there was no way to sign in, and there was no download — the Windows
 * installer existed only as a CI artifact behind a GitHub login.
 *
 * FOUR THINGS, and each one is a link that was missing:
 *
 *   1. Sign in         → the app
 *   2. Start free trial → the app's signup
 *   3. Download         → the current release from app_releases (0082)
 *   4. Prices           → read from `plans`, so the site cannot quote a figure
 *                         the console does not charge
 *
 * NO FRAMEWORK, NO BUILD. The site is static HTML served from a CDN and it stays
 * that way: a marketing page that needs npm to change a phone number is a
 * marketing page nobody changes.
 *
 * EVERY NETWORK READ HERE IS OPTIONAL. If Supabase is unreachable, or the config
 * is blank, the page keeps the prices written into the HTML and the download
 * button says the installer is being prepared. A visitor must never see a broken
 * page because a fetch failed — and the CI check keeps the hardcoded prices in
 * step with the database so the fallback is not a lie.
 * =========================================================================== */
(function () {
  'use strict'

  var C = window.SITE_CONFIG || {}
  var app = String(C.APP_URL || '').replace(/\/+$/, '')

  // ---- 1 & 2. Everything that points into the app ------------------------
  //
  // Driven off data attributes rather than ids, so a new button in the HTML is
  // wired by adding `data-app="signup"` and nothing here changes.
  var ROUTES = { signin: '/login', signup: '/signup', billing: '/settings', portal: '/portal' }

  function wireAppLinks() {
    var nodes = document.querySelectorAll('[data-app]')
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i]
      var route = ROUTES[el.getAttribute('data-app')] || '/'
      if (!app) {
        // Honest rather than dead. A button that silently does nothing sends the
        // visitor away; one that says the address is not set yet gets somebody
        // to fix config.js.
        el.setAttribute('href', '#contact')
        el.setAttribute('title', 'Set APP_URL in site/config.js to point this at the software')
        el.setAttribute('data-unwired', '1')
        continue
      }
      el.setAttribute('href', app + route)
      if (el.getAttribute('data-app') !== 'signin') el.setAttribute('rel', 'noopener')
    }
    if (!app) {
      var warn = document.getElementById('wire-warning')
      if (warn) warn.hidden = false
    }
  }

  // Signup closed: the trial buttons become an invitation to get in touch. The
  // alternative is a button that leads to a signup form which refuses them,
  // which is a worse first impression than being asked to call.
  function applySignupSwitch() {
    if (C.SIGNUP_OPEN !== false) return
    var nodes = document.querySelectorAll('[data-app="signup"]')
    for (var i = 0; i < nodes.length; i++) {
      nodes[i].setAttribute('href', '#contact')
      nodes[i].textContent = 'Talk to us about joining'
    }
    var note = document.getElementById('signup-closed')
    if (note) note.hidden = false
  }

  // ---- contact details, from one place ----------------------------------
  function wireContact() {
    var map = {
      'contact-phone': C.CONTACT_PHONE && { href: 'tel:' + String(C.CONTACT_PHONE).replace(/\s/g, ''), text: C.CONTACT_PHONE },
      'contact-whatsapp': C.CONTACT_WHATSAPP && {
        href: 'https://wa.me/' + String(C.CONTACT_WHATSAPP).replace(/[^\d]/g, ''),
        text: 'WhatsApp ' + C.CONTACT_WHATSAPP,
      },
      'contact-email': C.CONTACT_EMAIL && { href: 'mailto:' + C.CONTACT_EMAIL, text: C.CONTACT_EMAIL },
    }
    var any = false
    Object.keys(map).forEach(function (id) {
      var el = document.getElementById(id)
      if (!el) return
      var v = map[id]
      if (!v) { el.hidden = true; return }
      el.setAttribute('href', v.href)
      el.textContent = v.text
      el.hidden = false
      any = true
    })
    // The "fill these in" note goes away as soon as one is set. Leaving it
    // beside a real phone number would look like the site was half finished.
    var todo = document.getElementById('contact-todo')
    if (todo) todo.hidden = any
  }

  // ---- Supabase REST, by hand -------------------------------------------
  //
  // Two GETs. Pulling in the supabase-js library to make two unauthenticated
  // reads would be 40KB for something fetch does in four lines.
  function rest(path) {
    if (!C.SUPABASE_URL || !C.SUPABASE_ANON_KEY) return Promise.resolve(null)
    return fetch(String(C.SUPABASE_URL).replace(/\/+$/, '') + '/rest/v1/' + path, {
      headers: {
        apikey: C.SUPABASE_ANON_KEY,
        Authorization: 'Bearer ' + C.SUPABASE_ANON_KEY,
        Accept: 'application/json',
      },
    })
      .then(function (r) { return r.ok ? r.json() : null })
      // Swallowed on purpose. The page already has usable content; a failed
      // fetch must not replace it with an error.
      .catch(function () { return null })
  }

  // ---- 4. Live prices ----------------------------------------------------
  function money(n) {
    return 'Rs ' + Number(n).toLocaleString('en-PK', { maximumFractionDigits: 0 })
  }

  function wirePrices() {
    return rest('plans?select=code,name,student_limit,price_monthly,price_yearly&active=eq.true&order=sort_order')
      .then(function (plans) {
        if (!plans || !plans.length) return
        plans.forEach(function (p) {
          var card = document.querySelector('[data-plan="' + p.code + '"]')
          if (!card) return
          var monthly = card.querySelector('[data-price-monthly]')
          var yearly = card.querySelector('[data-price-yearly]')
          var cap = card.querySelector('[data-price-cap]')
          // A plan priced at zero is the "contact us" tier. Writing "Rs 0" on it
          // would be worse than leaving the words that are already there.
          if (monthly && Number(p.price_monthly) > 0) {
            monthly.textContent = money(p.price_monthly)
          }
          if (yearly && Number(p.price_yearly) > 0) {
            yearly.textContent = money(p.price_yearly) + ' a year'
          }
          if (cap && p.student_limit) {
            cap.textContent = 'Up to ' + Number(p.student_limit).toLocaleString('en-PK') + ' students'
          }
        })
        // The headline price in the hero, kept in step with the cheapest plan
        // rather than typed twice.
        var cheapest = plans.filter(function (p) { return Number(p.price_monthly) > 0 })[0]
        var lead = document.getElementById('lead-price')
        if (lead && cheapest) lead.textContent = money(cheapest.price_monthly)
      })
  }

  // ---- 3. The installer --------------------------------------------------
  function bytes(n) {
    if (!n) return ''
    var mb = Number(n) / (1024 * 1024)
    return mb >= 1 ? ' · ' + mb.toFixed(0) + ' MB' : ''
  }

  function wireDownload() {
    var box = document.getElementById('download-box')
    if (!box) return Promise.resolve()
    return rest('app_releases?select=version,url,sha256,size_bytes,notes,published_at&platform=eq.windows&channel=eq.stable&is_current=is.true&limit=1')
      .then(function (rows) {
        var r = rows && rows[0]
        if (!r) return          // the "being prepared" text already in the HTML
        var btn = document.getElementById('download-btn')
        btn.setAttribute('href', r.url)
        btn.textContent = 'Download for Windows'
        btn.removeAttribute('aria-disabled')
        btn.classList.remove('btn--ghost')
        btn.classList.add('btn--primary')

        document.getElementById('download-meta').textContent =
          'Version ' + r.version + bytes(r.size_bytes)
          + (r.published_at ? ' · ' + new Date(r.published_at).toLocaleDateString('en-PK', {
            year: 'numeric', month: 'short', day: 'numeric',
          }) : '')

        // The checksum, in full, because a school that has been told to check it
        // needs the whole thing — and because publishing it is the only reason
        // the check means anything.
        var sum = document.getElementById('download-sha')
        sum.textContent = r.sha256
        sum.parentElement.hidden = false

        if (r.notes) {
          var notes = document.getElementById('download-notes')
          notes.textContent = r.notes
          notes.hidden = false
        }
      })
  }

  function start() {
    wireAppLinks()
    applySignupSwitch()
    wireContact()
    wirePrices()
    wireDownload()
    var yr = document.getElementById('yr')
    if (yr) yr.textContent = String(new Date().getFullYear())
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start)
  } else {
    start()
  }
})()

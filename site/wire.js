/* ===========================================================================
 * Joining the website to the software.
 *
 * Before this file, site/index.html linked only to its own anchors: every
 * "Start free trial" button scrolled the visitor down the page they were already
 * on, there was no way to sign in, and there was no download at all.
 *
 * FIVE THINGS:
 *
 *   1. Sign in         -> the app
 *   2. Start free trial -> the app's signup
 *   3. Download         -> the current release from app_releases (0082), and the
 *                          whole section HIDES ITSELF when there is no release
 *   4. Prices           -> read from `plans`, so the site cannot quote a figure
 *                          the console does not charge
 *   5. The mobile menu  -> closing behaviour for the <details> disclosure
 *
 * NO FRAMEWORK, NO BUILD. The site is static HTML served from a CDN and it stays
 * that way: a marketing page that needs npm to change a phone number is a
 * marketing page nobody changes.
 *
 * EVERY NETWORK READ HERE IS OPTIONAL. If Supabase is unreachable, or the config
 * is blank, the page keeps the prices written into the HTML and the download
 * section stays hidden. A visitor must never see a broken page because a fetch
 * failed, and the CI check keeps the hardcoded prices in step with the database
 * so the fallback is not a lie.
 * =========================================================================== */
(function () {
  'use strict'

  var C = window.SITE_CONFIG || {}
  var app = String(C.APP_URL || '').replace(/\/+$/, '')
  // A value with no scheme is a RELATIVE path, so 'app.schoolmanager.pk' sends
  // every button to a same-origin 404 on the marketing host while looking
  // perfectly correct in config.js. Treated as unset so the honest degradation
  // below fires and #wire-warning appears, which is what gets it fixed.
  if (app && !/^https?:\/\//.test(app)) app = ''

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

    // The sticky mobile bar's WhatsApp button. It is the second most tapped
    // thing on a phone after the trial button, and it is useless without a
    // number, so it is removed rather than left pointing at wa.me/ with no
    // recipient.
    var bar = document.getElementById('bar-whatsapp')
    if (bar) {
      if (C.CONTACT_WHATSAPP) {
        bar.setAttribute('href', 'https://wa.me/' + String(C.CONTACT_WHATSAPP).replace(/[^\d]/g, ''))
        bar.setAttribute('rel', 'noopener')
      } else {
        bar.hidden = true
      }
    }
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
          // The code goes into a selector, so it is validated rather than
          // trusted. A row with a code of "] , *" would otherwise either throw
          // or match every card on the page.
          if (typeof p.code !== 'string' || !/^[a-z0-9_-]+$/i.test(p.code)) return
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
        // By PRICE, not by position. This took plans[0] of a list ordered by
        // sort_order, so with growth ahead of starter the hero read "From
        // Rs 2,000" above a Rs 950 card. "From" is a promise about the minimum.
        var cheapest = plans.filter(function (p) { return Number(p.price_monthly) > 0 })
          .reduce(function (a, b) {
            return Number(b.price_monthly) < Number(a.price_monthly) ? b : a
          }, null)
        var lead = document.getElementById('lead-price')
        if (lead && cheapest) lead.textContent = money(cheapest.price_monthly)
      })
      // The only network consumer here that had no catch. A throwing row in the
      // middle of the loop left the cards half rewritten: some plans updated,
      // the rest showing the HTML fallback, with no error anywhere. The
      // fallback prices are CI-checked against the database, so falling back
      // silently is correct; falling over halfway is not.
      .catch(function () {})
  }

  // ---- 3. The installer --------------------------------------------------
  //
  // THIS USED TO LEAVE A DEAD BUTTON ON THE PAGE, and that was reported as a
  // broken link. It was not broken: there is no published release, so the
  // fallback text "Windows installer: being prepared" was correct. But the
  // visitor cannot tell the difference between an honest placeholder and a site
  // that does not work, and the nav carried a Download link straight to it.
  //
  // You cannot link to a file that does not exist, so the answer is to stop
  // advertising the download until there is one. The section and every id stay
  // in the markup, because CI asserts they exist and because the day a release
  // is published this lights up with no further edit.
  function bytes(n) {
    if (!n) return ''
    var mb = Number(n) / (1024 * 1024)
    return mb >= 1 ? ' · ' + mb.toFixed(0) + ' MB' : ''
  }

  /*
   * With no release published, hide the ROUTES to the download page but never
   * the section itself.
   *
   * On the one-page site the section sat mid-page, so hiding it was right: an
   * unpublished installer should not leave a dead block between two live ones.
   * /download is now a page of its own, and hiding its only section would serve
   * a visitor who typed the address a heading with nothing under it. The button
   * already reads "Windows installer: being prepared", which is the honest
   * state, so the page is correct with the section left alone.
   *
   * The selector follows the link, which is now a URL rather than an in-page
   * anchor. Left as '#download' this matched nothing and the footer entry
   * stayed hidden for ever, including after a release was published.
   */
  function hideDownload() {
    var links = document.querySelectorAll('a[href="/download"]')
    for (var i = 0; i < links.length; i++) {
      var li = links[i].closest('li')
      if (li) { li.hidden = true } else { links[i].hidden = true }
    }
  }

  function wireDownload() {
    var box = document.getElementById('download-box')
    if (!box) return Promise.resolve()
    return rest('app_releases?select=version,url,sha256,size_bytes,notes,published_at&platform=eq.windows&channel=eq.stable&is_current=is.true&limit=1')
      .then(function (rows) {
        var r = rows && rows[0]
        if (!r || !r.url) { hideDownload(); return }

        // The nav and footer entries ship hidden, so a visitor with no
        // JavaScript is never pointed at a download that does not exist. They
        // come back here once a release is published.
        var routes = document.querySelectorAll('a[href="/download"]')
        for (var k = 0; k < routes.length; k++) {
          var host = routes[k].closest('li') || routes[k]
          host.hidden = false
        }

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

        // The checksum stays, because publishing it is the only reason checking
        // it means anything. But it is behind a disclosure rather than printed
        // in full: the buyer is a school owner, he does not know what a checksum
        // is, he will never verify one, and 64 characters of hexadecimal across
        // his phone screen is spatially the largest thing in the section.
        var sum = document.getElementById('download-sha')
        if (sum) {
          sum.textContent = r.sha256
          var wrapper = sum.closest('details') || sum.parentElement
          if (wrapper) wrapper.hidden = false
        }

        if (r.notes) {
          var notes = document.getElementById('download-notes')
          notes.textContent = r.notes
          notes.hidden = false
        }
      })
      .catch(function () { hideDownload() })
  }

  // ---- 5. The mobile menu ------------------------------------------------
  //
  // The disclosure itself is a <details>, so it opens and closes with no
  // JavaScript and is keyboard accessible for free. This adds only the three
  // behaviours a <details> does not give you, each of which is a way a visitor
  // gets stranded with the panel open over the page.
  function wireMenu() {
    var menu = document.getElementById('navmenu')
    if (!menu) return

    // Tapping a link inside it navigates, and the panel must not stay open over
    // the destination.
    menu.addEventListener('click', function (e) {
      var a = e.target.closest && e.target.closest('a')
      if (a) menu.removeAttribute('open')
    })

    // Escape closes it, which is what every other disclosure on the web does.
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && menu.hasAttribute('open')) {
        menu.removeAttribute('open')
        var s = menu.querySelector('summary')
        if (s) s.focus()
      }
    })

    // Rotating a phone to landscape can cross the 860px breakpoint, at which
    // point the real nav returns and the open panel would hang below it.
    if (window.matchMedia) {
      var mq = window.matchMedia('(min-width: 860px)')
      var onChange = function (ev) { if (ev.matches) menu.removeAttribute('open') }
      if (mq.addEventListener) { mq.addEventListener('change', onChange) }
      else if (mq.addListener) { mq.addListener(onChange) }
    }
  }

  function start() {
    wireAppLinks()
    applySignupSwitch()
    wireContact()
    wireMenu()
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

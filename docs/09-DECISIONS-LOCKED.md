# 09 — Locked Decisions (authoritative)

This document records the **final decisions** the owner made after the initial plan. **Where docs 01–08 differ from what's here, this document wins.** The initial plan assumed a fleet the seller hosts centrally; the real model is different and simpler.

## The deployment model (the big change)
The seller does **not** host a fleet. When a school buys:
- The seller sets up, on the **school's own Google account**: a **Supabase** project (their database + auth + storage), a **GitHub** repo, **web hosting** (Cloudflare Pages / Vercel), and installs the **desktop app** on the school's Windows PC.
- From then on, the school **owns and runs their own backend and data.** The seller just builds the product, stamps out a copy per sale, and teaches the workflow.

Consequence: there is **no shared cloud control plane, no per-tenant billing the seller pays, no licensing fleet, no central SMS relay.** Each school is a self-contained deployment. Setup steps are in [`SETUP-PER-SCHOOL.md`](SETUP-PER-SCHOOL.md).

## Locked answers
| # | Decision | Final |
|---|----------|-------|
| 1 | Product name | **"{School Name} Manager"** — branding is per-school config (e.g. *City Public School Manager*) |
| 2 | Who builds | **Claude builds it**; the owner does the manual/business tasks with step-by-step instructions |
| 3 | Scope | **Full v1.0**, everything — built **step by step**, starting from Phase 0 foundation |
| 4 | First build step | **Phase 0 foundation** (repo, database schema, app shell) — done in this change |
| 5 | Desktop OS | **Windows 10 & 11** (Win 7/8 can't run modern app frameworks in 2026; they fall back to the browser, best-effort) |
| 6 | Language | **English only** — no Urdu anywhere. (Deletes all RTL/Nastaliq/bilingual work.) |
| 7 & 8 | Parent messaging | **No messaging system.** WhatsApp = a **clickable number** on the student profile that opens WhatsApp with that contact for manual chat. (Deletes the SMS/WhatsApp engine, gateways, PTA masking, messaging costs.) |
| 9 | Backup | Data lives in each school's **Supabase** (managed backups); plus an in-app **"Export all data"** button so the school always owns a copy |
| 10 | Pilot | The owner finds pilot schools himself |
| 11 | Budget | Not the seller's concern — each school pays for its own Supabase/hosting |

## What this deletes from the original plan
- ❌ Shared cloud control plane, licensing heartbeat, fleet telemetry, anti-piracy licensing (§ in 04/06) — **not needed**; each school self-hosts.
- ❌ SMS/WhatsApp automation engine, gateways, masked sender IDs, messaging wallet economics — **replaced** by a click-to-WhatsApp link.
- ❌ Urdu / RTL / Noto Nastaliq / bilingual templates — **English only**.
- ❌ The offline **LAN local-server + HTTPS-on-LAN** architecture — **replaced** by Supabase cloud (one database in the cloud, both apps are clients → still no sync engine).

## What this keeps (still true and important)
- ✅ **One database, both surfaces** — but now it's the school's **Supabase** database in the cloud, with the admin "desktop" app and the teacher "web" app as clients. No two-database sync engine, same as before.
- ✅ The **data model** and its four historical-integrity rules ([`02-DATA-MODEL.md`](02-DATA-MODEL.md)) — implemented in `supabase/migrations/0001_core_schema.sql`.
- ✅ **Roles & permissions**, **audit log**, **append-only money/marks/attendance**, **soft-delete** — enforced by Postgres Row Level Security + triggers.
- ✅ The **full feature map** ([`03-FEATURES.md`](03-FEATURES.md)), minus the messaging engine and Urdu.
- ✅ Anti-fraud that matters: append-only payments, gapless receipt numbers, expected-vs-collected, the audit log.

## The one honest trade-off to keep in mind
A **cloud (Supabase) backend needs internet.** During a combined power + internet outage a cloud-backed app is unavailable. Mitigation: the **daily attendance screen is built offline-tolerant** (queues marks locally, syncs on reconnect); admin/fee work is online. Each school needs a reliable connection + a UPS on the PC/router. If a specific school's outages are severe, we revisit a local option for them — but the default is cloud.

## Current build status (Phase 0)
- ✅ Repo scaffold: `web/` (React + Vite + TypeScript + Tailwind), `supabase/` (schema + seed).
- ✅ Database schema: 30 tables, role-based RLS (61 policies), append-only + audit triggers, gapless counters — validated on Postgres 16.
- ✅ App shell: Supabase auth, role-based navigation, school-branded layout, module placeholders — builds clean.
- ⏭️ Next: the Auth phase (profile auto-provisioning trigger, user management UI), then the Fees and Attendance modules. See [`05-ROADMAP.md`](05-ROADMAP.md).

# Per-School Setup Guide — OBSOLETE

**This guide described the old model and no longer applies. Do not follow it.**

It told you to create a separate Supabase project, deployment and set of logins
for every school that bought the product. That is no longer how the system
works, and doing it would leave you with schools that cannot be managed from the
operator console.

**All schools now share one Supabase project.** A school is identified by who
logs in, not by which copy of the app they run. Setup happens **once**, not once
per school, and after that schools sign themselves up.

Why it changed: a project per school cost roughly $10/month each plus $100/month
each for point-in-time recovery, which at 100 schools is $1,000/month before
earning anything — with the recovery safety net priced out of reach. One shared
project costs ~$25–50/month in total regardless of how many schools there are,
with one backup and one upgrade path for everyone.

## What to read instead

**[SETUP.md](SETUP.md)** — the one-time setup, step by step, and what you do
day to day when a school signs up or pays.

This file is kept only so that a link or a bookmark to it does not lead
somewhere silently wrong.

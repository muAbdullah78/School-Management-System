-- =============================================================================
-- GENERATED FILE — DO NOT EDIT.
-- Built from supabase/migrations/ by supabase/build-bundles.sh
--
-- Paste this whole file into the Supabase SQL Editor and press Run.
-- Run the bundles in order, one at a time, waiting for each to finish.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────
-- 0032_parent_role.sql
-- ─────────────────────────────────────────────────────────────────────────
-- =============================================================================
-- Add the 'parent' role to user_role — and NOTHING else.
--
-- This file exists solely because of a Postgres rule:
--
--     ALTER TYPE ... ADD VALUE cannot be USED in the same transaction that
--     added it.  (ERROR 55P04: unsafe use of new value ...)
--
-- The portal migration originally did both — added 'parent' and then defined
-- is_staff(), is_parent() and my_family_id() which compare against it. Under
-- `psql` that works, because psql autocommits each statement, so the ALTER
-- lands in its own transaction. It is NOT how the migrations actually get
-- applied: the Supabase SQL Editor wraps the whole pasted file in a single
-- transaction, so the ALTER and the usage were in one, and it failed.
--
-- Splitting it into its own file guarantees the value is committed before
-- anything references it, whichever way the file is run. Keep it that way:
-- do not add anything else here, and do not fold this back into 0033.
--
-- CI now applies every migration with --single-transaction so this class of
-- bug fails the build instead of reaching a school.
-- =============================================================================

alter type public.user_role add value if not exists 'parent';

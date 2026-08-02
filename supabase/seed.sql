-- =============================================================================
-- Seed data for a FRESH school database.
-- Run after the migration. This inserts sensible starting config that the
-- school edits in-app (Settings). The owner login is created separately via
-- Supabase Auth during setup — see docs/SETUP-PER-SCHOOL.md.
-- =============================================================================

-- Singleton school settings row (name is edited in-app; app title = "{name} Manager").
insert into public.school_settings (id, name) values (1, 'Your School')
  on conflict (id) do nothing;

-- Current academic session (edit dates/name in Settings).
insert into public.academic_sessions (name, is_current, starts_on, ends_on)
  values ('2025-2026', true, '2025-04-01', '2026-03-31');

-- Example class ladder — fully editable. `level_order` orders the ladder and is
-- deliberately spaced by 10 so classes can be inserted between later.
insert into public.classes (name, level_order) values
  ('Play Group', 10), ('Nursery', 20), ('Prep', 30),
  ('Class 1', 40), ('Class 2', 50), ('Class 3', 60), ('Class 4', 70),
  ('Class 5', 80), ('Class 6', 90), ('Class 7', 100), ('Class 8', 110),
  ('Class 9', 120), ('Class 10', 130);

-- Common fee heads (set per-class amounts in Settings → Fees).
insert into public.fee_heads (name, type, is_recurring, is_refundable, sort_order) values
  ('Monthly Tuition Fee', 'monthly', true, false, 10),
  ('Admission Fee', 'admission', false, false, 20),
  ('Annual Charges', 'annual', false, false, 30),
  ('Exam Fee', 'exam', false, false, 40),
  ('Security Deposit', 'security_deposit', false, true, 50);

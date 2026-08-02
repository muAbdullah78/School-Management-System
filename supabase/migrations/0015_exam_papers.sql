-- =============================================================================
-- Exam papers: add a time-of-day to each paper so the date sheet and admit cards
-- can show when each exam sits. The paper's date already exists on
-- exam_subjects.exam_date (0001); this just adds the optional time (kept as free
-- text like "09:00 AM" so schools can write it however they like).
-- =============================================================================

alter table public.exam_subjects add column paper_time text;

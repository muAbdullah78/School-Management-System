# Exam computation — the design, and the argument against each decision

A result card is the most-argued-with document a school produces. A fee challan
that is wrong gets corrected at the counter; a result card that is wrong is shown
to a child's father, compared with a cousin's, and remembered for years. So this
part gets designed before it gets written.

Everything below was **demonstrated first**, on a real database, before any of it
was changed. The demonstration is in section 1 and the assertions that keep it
fixed are in `supabase/tests/exam_computation.sql`.

---

## 1. What was actually wrong

One class of nine, class 9, three subjects: English for everybody, Physics for the
Science stream, Civics for the Arts stream. Three pupils — one Science, one Arts,
and one whose marks simply had not been entered yet. Everyone who sat a paper did
well.

`fn_generate_result_cards` produced this:

| Pupil | Stream | Card said | Truth |
|---|---|---|---|
| Arts Child | Arts | 180/275 = **65.45%**, grade **C**, position **1** | 180/200 = 90.0%, A+ |
| Science Child | Science | 160/275 = **58.18%**, grade **D**, position **2** | 160/175 = 91.4%, A+ |
| Unmarked Child | Science | 0/275 = **0.00%**, grade **F**, position **3** | not marked yet |

Three separate defects, and each one on its own is enough to lose a school.

**1a. Streams turned two A+ pupils into a C and a D.** `total_max` was the sum of
*every* paper in the class, so a Science pupil was marked out of the Arts syllabus
as well and a zero was silently supplied for a paper they were never meant to sit.
`subjects.stream` and `enrollments.stream` had existed since the schema was
written and nothing read either of them.

**1b. It inverted the ranking.** On the true figures the Science pupil (91.4%)
comes first and the Arts pupil (90.0%) second. The card had them the other way
round, because the wrong denominator punished the Science pupil harder — Physics
was out of 75, so the missing Civics 100 hurt more. Prize day would have gone to
the wrong child, and nothing in the system would have said so.

**1c. A pupil nobody had marked was printed as having failed.** Not blank, not
"pending" — `0.00%`, grade `F`, ranked third. The cause is one `coalesce(sum(…),
0)`: a mark that does not exist and a mark of zero were the same thing to it.

**1d. `exam_subjects.practical_max` reached nothing.** A school could set Physics
theory 75 + practical 25 and there was nowhere to enter the practical mark —
`mark_entries` had a single `marks` column. The card said "out of 75".

**1e. The marksheet asked teachers to mark pupils who never sat the paper.** The
Physics marksheet listed all three pupils, Arts child included. A teacher either
leaves them blank (→ 1c) or types something, and typing something is worse.

**1f. `exam_subjects.pass_marks` was frozen onto every card and never used.** No
card said Pass or Fail. Pakistani result cards say Pass or Fail.

---

## 2. Decisions

### D1 — A subject belongs to one stream, or to everybody

`subjects.stream is null` means every pupil in the class takes it. A value means
only pupils whose `enrollments.stream` matches take it.

Compared **case-insensitively and trimmed**, because a school that types
`science` in one place and `Science` in another would otherwise silently exclude
every pupil from every streamed paper — a defect that looks exactly like 1a and
would be blamed on the software, correctly.

**The objection:** a pupil could take one subject from another stream (a Science
pupil doing Civics as an extra). This model cannot express that.

**Why I am accepting it:** the alternative is a per-pupil subject table, which
means a school must enrol every pupil in every subject before any exam works at
all — turning a five-minute setup into an afternoon, for every term. Streams
cover the case that actually occurs in Pakistani schools 9–12. If a real school
asks for per-pupil electives, the honest answer is to build a subject-enrolment
table then, not to half-build one now.

**The trap this opens, and how it is closed:** if a school sets up streamed
subjects and forgets to set a pupil's stream, that pupil quietly gets a card with
only the common subjects on it and nobody notices — the same silent wrongness in
a new place. So generation **refuses** when a class has streamed subjects and any
pupil in it has no stream, and names the pupils. A refusal is recoverable; a
plausible wrong card is not.

### D2 — Refuse to generate an incomplete card

Generation counts the (pupil, subject-they-actually-take) pairs with no mark
entered. If any exist it raises, naming the subjects and how many pupils each is
missing for.

**The objection:** this is annoying. A principal who wants to see provisional
results now is blocked by the software.

**Why the refusal wins anyway:** the thing being prevented is handing a parent a
document that says their child failed, when the truth is that a teacher had not
finished typing. There is no version of that trade where the convenience wins.
And the refusal is *more* useful than what it replaces: "Chemistry is missing for
12 pupils" tells the principal exactly who to chase, where a silent zero told
them nothing.

`p_allow_incomplete => true` proceeds. When it does, two things change together:

- the card is stamped **provisional** and prints as such, and
- unmarked subjects are **excluded from the denominator** rather than counted as
  zeros.

Both, not one. A provisional card that still divides by the full total is just
defect 1c with a label on it.

### D3 — "Absent" and "not marked" are different facts

- `is_absent = true` → counted as **0**, and the subject **stays** in the
  denominator. The pupil was expected and did not sit; a zero is the consequence.
- **no row at all** → not marked. Never a zero. Either the generation refuses
  (D2) or the subject leaves the denominator.

This distinction is what makes D2 possible, and it is the reason the mark-entry
screen must have an explicit Absent control rather than letting a teacher express
absence by leaving a box empty.

### D4 — Practical marks get their own column

`mark_entries.practical_marks numeric`, validated against
`exam_subjects.practical_max`.

- subject obtained = `coalesce(marks,0) + coalesce(practical_marks,0)`
- subject max = `max_marks + practical_max`

**Why not model the practical as its own subject row?** Because then a card
prints "Physics" and "Physics Practical" as two subjects, position is computed
over twice as many rows, and `practical_max` means nothing. A Pakistani result
card has one row per subject with theory and practical columns and a combined
total. The frozen snapshot therefore keeps theory and practical **separate** as
well as storing the combined figures, so the print can show either.

**`subjects.is_practical` finally gets a job.** It means *this subject has a
practical component*. The exam-setup screen shows the practical-max field only
when it is set, the marksheet shows a practical column only then, and
`fn_upsert_exam_subject` refuses a `practical_max > 0` on a subject that is not
flagged. Without that pairing the two columns can disagree, and disagreeing
columns are how a practical mark ends up somewhere nobody looks.

**Pass mark with a practical:** applied to the **combined** total. Some boards
require passing theory and practical separately; that varies by board and year,
and guessing is worse than being clear. The card prints theory, practical and
combined, so a school applying a different rule has the numbers in front of them.

### D5 — Pass or fail, stated

Per subject: obtained (combined) `>= pass_marks`. Overall: **Pass** when no
subject failed *and* the aggregate meets `school_settings.pass_percent`;
otherwise **Fail**, with the number of subjects failed.

**The objection:** plenty of schools promote on aggregate alone and would call
this too strict.

**The answer:** the card prints *both* facts — the aggregate percentage and
"failed in N subject(s)" — so a school with a different promotion rule can apply
it from what is printed. A configurable promotion engine is a feature nobody
asked for and a place for bugs to live. Stating the facts is not.

### D6 — Class assessments count only if the term says so

`exam_terms.assessment_weight_pct numeric default 0`.

**Zero is the default and zero means today's behaviour, exactly.** Nothing about
an existing term changes when this ships. That is deliberate: an engine that
silently starts reweighting the result cards of a school mid-session would be
indefensible, however correct the arithmetic.

When a term sets it to, say, 30: the exam papers carry 70% and the session's
assessments 30%. The assessment component is the weighted mean of the class's
assessments using `assessments.weightage` as the weight; an assessment with
weightage 0 is **excluded**, which is why every assessment that exists today
contributes nothing until somebody deliberately weights it.

**The trap, and how it is closed:** if a term sets 30% and no assessment carries
any weight, a naive engine gives every pupil 0 for 30% of their result. So the
rule is: **when a pupil has no weighted assessment, the exam component takes the
full 100%**, and the card records that it did. Never a zero for a component that
does not exist.

### D7 — `bise_reg_no` is a real field

Board registration numbers for classes 9–12. Editable on the enrolment, printed
on the result card when present, and exportable as a list, because the school
fills board forms from it. Absent for a primary class and simply not printed.

### D8 — A printed card says which one it is

`result_cards.generated_at` and `version` go on the print. A school that
regenerates after a correction ends up with two cards in circulation that look
identical; a date and a version number is how a parent's copy and the office copy
are told apart.

---

## 3. What is deliberately NOT built

- **Per-pupil subject enrolment / electives.** See D1.
- **A configurable promotion rule.** See D5.
- **GPA on the card.** `school_settings.grade_scale` offers `gpa10`, and
  `fn_grade_for` ignores it and always returns letters. That is a real gap and it
  is its own piece of work — the grade *bands* are what a school argues about, and
  a settings screen for bands is the fix, not a second hard-coded scale. Recorded
  here rather than quietly half-done.
- **Weighted marks inside a single paper** (question-wise). No school asked, and
  it multiplies the mark-entry surface by ten.

---

## 4. What this can and cannot prove

All of it is ordinary SQL over ordinary tables, so all of it is tested:
`supabase/tests/exam_computation.sql` rebuilds the exact fixture from section 1
and asserts the corrected figures, in both directions across two schools.

The one thing a test cannot check is whether the *bands* in `fn_grade_for` match
what a given school uses. They are the common Pakistani set (90/80/70/60/50) and a
school that disagrees needs the settings screen named in section 3.

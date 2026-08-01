# 02 — Data Model & Historical Integrity

The owner's flagship requirement is a **student profile that spans every year and can be queried decades later** — and that can **never be silently overwritten** when a child changes class. That is a data-modeling problem, and we solve it *structurally* so history is protected **by design, not by discipline**. It should be *impossible* to destroy a record by editing a class or a mark.

## Core hierarchy

```
Owner → Campus → Shift → Academic Session (Year) → Grade Level (Class) → Section → Enrollment → Student
```

Every core row carries `school_id` and `campus_id` **from day one**. A single-campus school pays nothing for this, but we never have to do a destructive migration when the owner opens a second branch or a morning/evening shift.

Why each level exists (grounded in how these schools really work):
- **Campus** — one owner often runs multiple branches and wants **consolidated reporting**.
- **Shift** — one building frequently runs a **morning and an evening shift** that are effectively separate schools (different students, staff, fees, even different class ladders). `shift` is a first-class partition, not an afterthought.
- **Academic Session** — the spine of all history (see Rule 2).
- **Class ladder is configurable, never a hardcoded enum** — no two schools agree on pre-primary names (Play Group / Nursery / Prep / KG / Kachi / Montessori I–III…). Classes are admin-editable, ordered entities.
- **Streams/groups** attach to class + student for Classes 9–12 (Science/Arts; Pre-Medical/Pre-Engineering/ICS/Commerce/FA) — a student's subject list depends on their group.

```mermaid
erDiagram
    STUDENT ||--o{ ENROLLMENT : "has one per session"
    ACADEMIC_SESSION ||--o{ ENROLLMENT : "scopes"
    SECTION ||--o{ ENROLLMENT : "places"
    CLASS ||--o{ SECTION : "splits into"
    STUDENT ||--o{ INVOICE : "billed"
    INVOICE ||--o{ INVOICE_LINE : "itemizes"
    INVOICE ||--o{ PAYMENT_ALLOCATION : "settled by"
    PAYMENT ||--o{ PAYMENT_ALLOCATION : "allocates"
    ENROLLMENT ||--o{ ATTENDANCE_DAILY : "records"
    ENROLLMENT ||--o{ MARK_ENTRY : "scores"
    EXAM_TERM ||--o{ MARK_ENTRY : "groups"
    STUDENT ||--o{ RESULT_CARD : "issued"
    USER ||--o{ AUDIT_LOG : "acts"
```

## The four rules that guarantee integrity

### Rule 1 — Separate identity from state
A **Student** is a durable *person*: permanent GR (General Register) Number, B-Form number (young children have a B-Form, not a CNIC), family link, bio-data. It holds **no** year-specific data.

Class, section, roll number, and BISE registration live in **Enrollment** — exactly **one row per student per session** (`UNIQUE(student_id, session_id)`). "Current class" is **derived** from the latest active enrollment, never stored on the student. Promotion, retention, section change, and transfer all **INSERT a new Enrollment** — they never UPDATE a prior year. This is what makes "full profile spanning all years" real, and makes it *impossible* to overwrite history by changing a class.

> **Registration No ≠ GR No.** The brief conflated these. Registration No is per-admission-attempt/annual; the **GR Number is the lifelong identifier**. We model both.

### Rule 2 — Academic Session is the spine
Every enrollment, invoice, attendance row, assessment, exam, mark, and fee plan carries an explicit `session_id`. Historical queries filter **by `session_id`**, never by an `is_current` flag. Closing or archiving a year never hides or mutates its data — it only marks it read-only.

### Rule 3 — Append-only where money, marks, and attendance live
The three things you must never silently mutate:

**Fees**
- `Payment` is **never edited or deleted**; a mistake is fixed by a *reversing linked payment* so the cash ledger always foots.
- `Invoice` becomes **immutable at `status = issued`**; corrections flow through an `Adjustment` (reason + approver required) or a void-and-reissue, never in-place edits.
- `InvoiceLine` / `InvoiceDiscount` **snapshot** head names and amounts, so editing the fee catalog later can't rewrite an old bill.
- Arrears are an explicit `arrears_brought_forward` field. A student's balance is **derived** from `PaymentAllocation` (one payment can settle many invoices) — there is **no single mutable "student owes X" number** to corrupt.

**Marks**
- `MarkEntry` — **one universal table** for both tests and exams, discriminated by `source_type` — freezes at `is_locked`. A re-mark stores `corrected_from_marks` + `correction_reason` + optional verifier. `max_marks` is snapshotted at entry.
- `ResultCard` freezes totals/grades/attendance% at generation; a regeneration creates a **new version** rather than overwriting a published card — a card reprinted years later is **byte-identical** to the original.

**Attendance**
- `AttendanceDaily` — one immutable row per student per day (`UNIQUE(enrollment_id, attendance_date)`); once finalized it **locks**, and any change records `corrected_from_status` + reason.
- `AttendanceRollup` — a **rebuildable** materialized monthly→yearly cache over that grain, for fast profile/report queries. Because it's derived, it can always be recomputed from the immutable daily rows.

### Rule 4 — Soft-delete everywhere, never physical delete
Every table carries `deleted_at`. Struck-off students, resigned staff, revoked discounts, and deactivated users are **flagged**, so foreign keys embedded in historical invoices, payments, and marks always resolve. Uniqueness constraints exclude soft-deleted rows where re-use is legitimate (a re-admitted student reusing a roll number).

## Discounts, adjustments, reversals — first-class and audited
The **highest fraud/dispute-risk** area. These are never free-text edits. Each is an **approvable, reason-required entity** with an approver and timestamp, written into a **discount register** the owner can review. Sibling/merit/staff-child/hardship/scholarship concessions all flow through it.

## The audit backstop (and its honest limits)
**AuditLog** is an append-only journal: every money / marks / attendance-correction / enrollment / permission mutation writes a **before → after** snapshot with actor, role, reason, source device, and an immutable timestamp.

**Honest limitation (do not over-sell this):** an app-layer append-only log inside a SQLite file on a PC that staff physically control can, in principle, be bypassed by someone with the raw `.db` file and a SQLite editor. So we make the log **tamper-*evident*, not merely append-only**:
- **Hash-chain** the audit and financial records; **periodically anchor** the chain hash to the cloud control plane, so any out-of-band edit becomes **detectable**.
- Encrypt the DB at rest with **SQLCipher**, with the key released by the licensed app (not sitting in plaintext beside the file).
- Reconcile local state against the **immutable cloud backup**.

Marketing language is therefore **"tamper-evident,"** never "impossible to tamper." See [`04-RISKS-AND-SAFEGUARDS.md`](04-RISKS-AND-SAFEGUARDS.md).

## Session close = lock, not delete
Closing an academic session makes its financial and mark records **read-only**; it never deletes them. BISE 9–12 registration/roll numbers and the chosen group survive as historical facts even after a student leaves the school.

## Entity checklist (MVP core)
`School`, `Campus`, `Shift`, `AcademicSession`, `Class`, `Section`, `Subject`, `Student`, `Guardian`, `Enrollment`, `FeeHead`, `FeePlan`, `Invoice`, `InvoiceLine`, `InvoiceDiscount`, `Payment`, `PaymentAllocation`, `Adjustment`, `Discount`(register), `AttendanceDaily`, `AttendanceRollup`, `AssessmentTest`, `ExamTerm`, `MarkEntry`, `ResultCard`, `Staff`, `User`, `Role`, `Permission`, `AuditLog`, `MessageLog`, `Backup`(metadata), `LicenseState`, `SchoolSettings`.

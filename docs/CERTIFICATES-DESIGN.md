# Certificates — the design, and the argument against each decision

A School Leaving Certificate is the document a Pakistani family **cannot enrol a
child anywhere else without**. It is also the school's main lever for unpaid
fees. Both of those were broken.

The certificate module already existed — a gapless per-type serial, a frozen
snapshot for reprints, append-only insert policies. All of that is sound and
stays. What follows is what it did not do.

---

## 1. What was actually wrong

One pupil, **still enrolled**, **owing Rs 4,000**. A leaving certificate was
requested.

| What happened | What should happen |
|---|---|
| Certificate issued, serial 1 | **Refused** — Rs 4,000 outstanding |
| `students.status` still `active`, `left_on` null, enrolment still `active` | the child is recorded as having left |
| Snapshot: name, father, class, roll — **and nothing else** | GR no, dates of attendance, date of leaving, conduct |
| Issued again → serial 2, **also looking original** | a second copy says **DUPLICATE** |
| No way to cancel one issued in error | a cancellation, recorded |

**1a. No dues check at all.** The one thing a school withholds until fees are
paid, handed over freely.

**1b. Issuing it did not record the leaving.** After the certificate, the child
was still `active` with no `left_on`. So they stay on the attendance sheet, in
the class strength, and **in next month's billing** — while holding a certificate
that says they have left. `students.left_on` and `fn_set_student_status` have
existed since 0054; the certificate path simply never touched them.

**1c. The snapshot was missing everything an SLC must state.** An SLC says "was a
bona fide student of this school from ___ to ___, last studying in class ___, and
his conduct was ___". `admission_date` was on the pupil's record and was not
copied. Dates of attendance, date of leaving, GR number, date of birth and
conduct were all absent — the wording was assembled from whatever a clerk had
typed into the free-form `data` field, so two clerks produced two different
documents.

**1d. Two originals.** Issuing twice produced serials 1 and 2, indistinguishable.
A school cannot then say which is the real one, and a family holding two can
present one at each of two schools.

**1e. No cancellation.** Append-only with no way to mark a mistake, so a
certificate issued to the wrong child stays valid for ever.

---

## 2. Decisions

### D1 — The dues gate is per certificate type

| Type | Dues gate |
|---|---|
| **leaving** | **Refused while anything is outstanding**, overridable by an owner or principal with a recorded reason |
| character | none |
| bonafide | none |
| id_card | none |

**Why only `leaving`:** a bonafide certificate is proof of enrolment — a family
needs it for a bank account, a passport, a scholarship form. A character
certificate is a statement about conduct. Withholding either over fees is
punitive and is not what schools do. The SLC is the one that genuinely gates
onward enrolment, and that is exactly why it is the lever.

**Why the override exists:** a hard refusal with no way through does not stop the
school releasing the certificate — it pushes them into issuing an `other`
certificate with the same text, where nothing is recorded at all. The override
requires owner or principal, and stamps the amount outstanding and who
authorised it **into the frozen snapshot**, so the document itself carries the
fact.

**The objection:** an override makes the gate soft. Yes — deliberately. A gate
that cannot be opened gets bypassed outside the system, and then the school has
neither the money nor the record.

### D2 — Issuing a leaving certificate RECORDS the leaving, atomically

The child is marked as having left in the same transaction that issues the
certificate. Not two steps.

**The objection, and it is the serious one:** printing a document should not
quietly change a pupil's status. A clerk who prints an SLC to check the wording
would remove a child from the roll.

**Why it still wins, and how the objection is answered:** the alternative — the
old behaviour — is a child holding a leaving certificate who is still on the
attendance register and still being billed. That drift is silent and it compounds
every month. Two steps mean the register is wrong whenever anyone forgets the
first one, and somebody always does.

The objection is answered by making it **explicit rather than implicit**: the
leaving date and reason are **required arguments** for a leaving certificate, not
optional extras. There is no way to issue one without stating when and why the
child left, so nobody issues one by accident to see the wording. And it calls
`fn_set_student_status` rather than writing the columns itself, so 0054's rules
(and its audit trail) apply unchanged.

If the pupil is **already** recorded as having left, the recorded date is used
and nothing is changed.

### D3 — The snapshot states what the certificate must state

Added to the frozen snapshot: `gr_no`, `admission_no`, `dob`, `gender`,
`admission_date`, `date_of_leaving`, `attended_from`, `attended_to`,
`class_name`, `section_name`, `roll_no`, `conduct`, `bise_reg_no`, `stream`,
`photo_path`, and the dues position at the moment of issue.

Frozen, not looked up at print time, for the reason the table was built that way:
a reprint five years later must produce the same document. The one deliberate
exception is the **photograph**, which is read live — a card or certificate
exists so somebody can recognise the child holding it.

`attended_from` is the admission date; `attended_to` is the date of leaving, or
today for a certificate issued to a current pupil.

### D4 — A second copy is a DUPLICATE and says so on its face

If a certificate of that type already exists for that pupil, the new one records
`is_duplicate: true` and `original_serial_no`, and the printed document carries
**DUPLICATE COPY**. It still gets its own serial, because the register must show
that a second document exists.

**Why not refuse a second one?** Originals get lost. A school that cannot issue a
replacement writes one by hand, and then there is no record at all.

### D5 — Cancellation is a separate row, not an edit

`certificate_cancellations`, one row per certificate, with a reason and who
cancelled it. `certificates` stays strictly append-only — an UPDATE path would
mean a certificate could be edited into something it never was, and RLS cannot
restrict *which columns* an update touches.

The register shows cancelled certificates struck through with the reason, rather
than hiding them: a cancelled serial is a fact somebody may need to explain.

### D6 — Only an owner or principal cancels, or overrides the dues gate

Both are decisions with consequences outside the school. A clerk issues
certificates all day; neither of these is clerical.

### D7 — The free-form field cannot assert anything the snapshot owns

`p_data` exists so a clerk can add conduct, a purpose and remarks. It was merged
**over** the snapshot, which meant every field D3 and D4 depend on was whatever
the caller chose to send. Probed rather than reasoned about, on a real database:

```
fn_issue_certificate('bonafide', <pupil owing Rs 4,000>, '{
  "is_duplicate": false, "dues_cleared": true, "balance_at_issue": 0,
  "student_name": "Somebody Else", "gr_no": "GR-9999" }')
```

produced serial 2 — a legitimate serial in the school's own register — printing a
different child's name and GR number, with **no DUPLICATE stamp**, stating the
fees as cleared while Rs 4,000 was outstanding. The function's own return value
said `is_duplicate: true` at the same moment; only the stored document disagreed.

The web app sends none of those keys. That is not a boundary: `fn_issue_certificate`
is granted to `authenticated`, so anything holding a clerk's session can call it
with any payload, and a certificate is exactly the document somebody has a motive
to forge.

The fix is one line and a named list: the snapshot's keys are **deleted from
`p_data`** before the merge. Deleting rather than merging the other way round,
because `jsonb_strip_nulls` removes a snapshot key that came out null — so
`p_data || v_snap` would still let `original_serial_no` through on a certificate
that is not a duplicate. The list is the whole answer to "what can the caller not
assert?", in one place, next to the merge it guards.

`conduct`, `purpose` and `remarks` still reach the document. Locking it down must
not empty it, and assertion 46 is there to fail if a later tightening does.

---

## 3. What is deliberately NOT built

- **A certificate template designer.** Schools will ask eventually. It is a
  large piece of work (layout, fonts, per-type templates, preview) and nobody has
  asked yet.
- **Urdu certificates.** The wording matters legally and machine translation is
  not good enough to put on a document a family presents to another school.
  Worth doing properly with a real translation, as its own task.
- **Verification by QR against a public endpoint.** The ID card already carries a
  QR of the GR number. A *verifiable* certificate — another school scanning it to
  confirm authenticity — needs a public endpoint, which is a security surface of
  its own and is not something to add casually to a system holding children's
  records.

---

## 4. What this can and cannot prove

`supabase/tests/certificates.sql` — 46 assertions — rebuilds the exact scenario
from section 1 and asserts the corrected behaviour: the refusal, the override with
its recorded reason, the leaving actually being recorded, the completeness of the
snapshot, the duplicate marking, the cancellation, that the free-form field cannot
forge any of it, and that none of it crosses a school boundary in either
direction.

What a test cannot decide is whether a given school's SLC wording satisfies a
particular board or a particular receiving school. The document states the facts
a Pakistani SLC states; the wording is in one place
(`web/src/pages/certificates/CertificatePrint.tsx`) so a school can be shown it
before they rely on it.
